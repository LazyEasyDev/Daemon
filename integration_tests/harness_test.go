//go:build linux

package integration_tests

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

const (
	domainUUID     = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
	builderUUID    = "11111111-2222-4333-8444-555555555555"
	preflightCalls = "list --all --name\nuuidgen\nlist --all --uuid\n"
)

// Keep the real virsh_command wrapper: its locale, connection and argument
// forwarding are part of the contract. A file records calls across subshells.
const libvirtMocks = `
set -Eeuo pipefail
LC_ALL=POSIX
libvirt_uri='mock:///harness connection'
record() { printf '%s\n' "$*" >>"$CALLS"; }
virsh() {
	if [[ ${LC_ALL-} != C || ${1-} != --connect || ${2-} != "$libvirt_uri" ]]; then
		record "unexpected virsh context: ${LC_ALL-} $*"
		return 99
	fi
	shift 2
	record "$@"
	case "$*" in
		'list --all --name')
			printf '%s\n' "${DOMAIN_NAMES-}"
			return "${NAME_STATUS:-0}" ;;
		'list --all --uuid')
			printf '%s\n' "${DOMAIN_UUIDS-}"
			return "${UUID_STATUS:-0}" ;;
		'destroy '*) return "${DESTROY_STATUS:-0}" ;;
		'undefine '*)
			if [[ ${3-} == --nvram ]]; then return "${NVRAM_STATUS:-0}"; fi
			return "${UNDEFINE_STATUS:-0}" ;;
		'dumpxml '*|'net-dhcp-leases '*) return "${DIAGNOSTIC_STATUS:-0}" ;;
		*) record "unexpected virsh command: $*"; return 99 ;;
	esac
}
uuidgen() {
	record uuidgen
	printf '%s\n' "${GENERATED_UUID-` + domainUUID + `}"
	return "${UUIDGEN_STATUS:-0}"
}
. "$HELPER"
`

type shellResult struct {
	status                int
	stdout, stderr, calls string
}

func readHarnessFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func commandPath(t *testing.T, name string) string {
	t.Helper()
	path, err := exec.LookPath(name)
	if err != nil {
		t.Fatalf("shell regression tests require %s: %v", name, err)
	}
	return path
}

func runShell(t *testing.T, shell, script string, env ...string) shellResult {
	t.Helper()
	helper, err := filepath.Abs("libvirt-domain.sh")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	calls := filepath.Join(dir, "calls")
	if err := os.WriteFile(calls, nil, 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, commandPath(t, shell), "-c", script)
	// No inherited BASH_ENV, exported functions or executable search path. An
	// unmocked command cannot reach virsh, rm, SSH or any other host executable.
	cmd.Env = append([]string{
		"PATH=" + dir, "HOME=" + dir, "LC_ALL=C", "HELPER=" + helper,
		"CALLS=" + calls, "ARTIFACT_DIR=" + dir,
	}, env...)
	cmd.Dir = dir
	cmd.WaitDelay = time.Second
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err = cmd.Run()
	if ctx.Err() != nil {
		t.Fatalf("%s timed out: %v\n%s", shell, ctx.Err(), stderr.String())
	}
	status := 0
	if err != nil {
		var exit *exec.ExitError
		if !errors.As(err, &exit) {
			t.Fatalf("run %s: %v", shell, err)
		}
		status = exit.ExitCode()
	}
	return shellResult{status, stdout.String(), stderr.String(), readHarnessFile(t, calls)}
}

func (r shellResult) check(t *testing.T, status int, stdout, calls string) {
	t.Helper()
	if r.status != status || r.stdout != stdout || r.calls != calls {
		t.Fatalf("exit=%d stdout=%q\ncalls:\n%sstderr:\n%s\nwant exit=%d stdout=%q\ncalls:\n%s",
			r.status, r.stdout, r.calls, r.stderr, status, stdout, calls)
	}
}

func TestNewDomainUUID(t *testing.T) {
	const names = "list --all --name\n"
	const generated = names + "uuidgen\n"
	for _, tc := range []struct {
		name  string
		env   []string
		calls string
		ok    bool
	}{
		{"existing-name", []string{"DOMAIN_NAMES=neighbor\ndaemon-test\nother"}, names, false},
		{"names-list-failed", []string{"NAME_STATUS=7", "DOMAIN_NAMES=other"}, names, false},
		{"uuids-list-failed", []string{"UUID_STATUS=7", "DOMAIN_UUIDS=" + builderUUID}, preflightCalls, false},
		{"uuid-collision", []string{"DOMAIN_UUIDS=" + builderUUID + "\n" + domainUUID}, preflightCalls, false},
		{"uuid-collision-uppercase", []string{"DOMAIN_UUIDS=" + strings.ToUpper(domainUUID)}, preflightCalls, false},
		{"invalid-uuid", []string{"GENERATED_UUID=not-a-uuid"}, generated, false},
		{"empty-uuid", []string{"GENERATED_UUID="}, generated, false},
		{"uuid-with-suffix", []string{"GENERATED_UUID=" + domainUUID + "-extra"}, generated, false},
		{"uuid-with-newline", []string{"GENERATED_UUID=" + domainUUID + "\n" + builderUUID}, generated, false},
		{"uuidgen-failed", []string{"UUIDGEN_STATUS=7"}, generated, false},
		{"empty-inventory", nil, preflightCalls, true},
		{"distinct-name", []string{"DOMAIN_NAMES=daemon-test-other\nprefix-daemon-test\nDAEMON-TEST", "DOMAIN_UUIDS=" + builderUUID}, preflightCalls, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			result := runShell(t, "bash", libvirtMocks+`
mkdir() { record mkdir "$@"; }
virt-install() { record virt-install "$@"; }
domain_name=daemon-test
domain_uuid=$(new_domain_uuid "$domain_name")
mkdir -p work
virt-install --name "$domain_name" --uuid "$domain_uuid"
printf '%s\n' "$domain_uuid"
`, tc.env...)
			status, stdout, calls := 1, "", tc.calls
			if tc.ok {
				status, stdout = 0, domainUUID+"\n"
				calls += "mkdir -p work\nvirt-install --name daemon-test --uuid " + domainUUID + "\n"
			}
			result.check(t, status, stdout, calls)
		})
	}
}

func removalCalls(uuid string, fallback bool) string {
	calls := "destroy " + uuid + "\nundefine " + uuid + " --nvram\n"
	if fallback {
		calls += "undefine " + uuid + "\n"
	}
	return calls
}

func TestRemoveOwnedDomain(t *testing.T) {
	for _, tc := range []struct {
		name     string
		env      []string
		fallback bool
	}{
		{"renamed-domain", nil, false},
		{"failed-before-create", []string{"DESTROY_STATUS=1", "NVRAM_STATUS=1", "UNDEFINE_STATUS=1"}, true},
		{"partial-create-stopped-domain", []string{"DESTROY_STATUS=1"}, false},
		{"nvram-fallback", []string{"NVRAM_STATUS=1"}, true},
		{"fallback-also-fails", []string{"NVRAM_STATUS=1", "UNDEFINE_STATUS=1"}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			result := runShell(t, "bash", libvirtMocks+`
domain_uuid=$(new_domain_uuid daemon-test)
domain_name=someone-elses-vm
DOMAIN_NAMES=$domain_name
DOMAIN_UUIDS=`+builderUUID+`
remove_owned_domain "$domain_uuid"
`, tc.env...)
			result.check(t, 0, "", preflightCalls+removalCalls(domainUUID, tc.fallback))
		})
	}
}

func TestRemoveOwnedDomainRejectsMissingOrInvalidIdentity(t *testing.T) {
	for _, tc := range []struct {
		name, identity string
		missing        bool
	}{
		{"missing", "", true},
		{"empty", "", false},
		{"mutable-name", "daemon-test", false},
		{"option", "--all", false},
		{"whitespace", " " + domainUUID, false},
		{"suffix", domainUUID + "-extra", false},
		{"non-hex", strings.ReplaceAll(domainUUID, "a", "g"), false},
		{"multiple", domainUUID + "\n" + builderUUID, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			call := `remove_owned_domain "$IDENTITY"`
			if tc.missing {
				call = "remove_owned_domain"
			}
			runShell(t, "bash", libvirtMocks+call, "IDENTITY="+tc.identity).check(t, 1, "", "")
		})
	}
}

func onlyMatch(t *testing.T, source, pattern string) string {
	t.Helper()
	matches := regexp.MustCompile(pattern).FindAllString(source, -1)
	if len(matches) != 1 {
		t.Fatalf("expected one match for %q, found %d", pattern, len(matches))
	}
	return matches[0]
}

func shellFunction(t *testing.T, source, name string) string {
	t.Helper()
	// These runners close top-level functions with an unindented brace.
	return onlyMatch(t, source, `(?ms)^`+regexp.QuoteMeta(name)+`\(\) \{\n.*?^\}`)
}

func TestSystemVCleanup(t *testing.T) {
	runner := readHarnessFile(t, "systemv/run-libvirt.sh")
	cleanup := shellFunction(t, runner, "cleanup")
	trap := onlyMatch(t, runner, `(?m)^trap cleanup EXIT$`)
	for _, tc := range []struct {
		name                    string
		status                  int
		dropDomain, dropBuilder bool
		env                     []string
		fallback                bool
	}{
		{"created", 0, false, false, nil, false},
		{"failed-before-create", 29, false, false, []string{"DESTROY_STATUS=1", "NVRAM_STATUS=1", "UNDEFINE_STATUS=1", "DIAGNOSTIC_STATUS=1"}, true},
		{"partial-create-stopped-domain", 29, false, false, []string{"DESTROY_STATUS=1"}, false},
		{"builder-already-removed", 0, false, true, nil, false},
		{"only-builder-owned", 29, true, false, nil, false},
		{"missing-identities", 29, true, true, nil, false},
	} {
		for _, keep := range []string{"0", "1"} {
			t.Run(tc.name+"/KEEP_VM="+keep, func(t *testing.T) {
				env := append([]string{
					"KEEP_VM=" + keep, fmt.Sprintf("RUN_STATUS=%d", tc.status),
					fmt.Sprintf("DROP_DOMAIN=%t", tc.dropDomain), fmt.Sprintf("DROP_BUILDER=%t", tc.dropBuilder),
				}, tc.env...)
				// Execute only the actual cleanup and EXIT trap, not the runner.
				// Artifact redirections stay in t.TempDir; every external effect is mocked.
				result := runShell(t, "bash", libvirtMocks+`
domain_name=daemon-test
domain_uuid=$(new_domain_uuid "$domain_name")
GENERATED_UUID=`+builderUUID+`
builder_uuid=$(new_domain_uuid "$domain_name-builder")
domain_name=someone-elses-vm
builder_domain=someone-elses-builder
if [[ $DROP_DOMAIN == true ]]; then domain_uuid=; fi
if [[ $DROP_BUILDER == true ]]; then builder_uuid=; fi
keep_vm=$KEEP_VM
artifact_dir=$ARTIFACT_DIR
work_dir='mock work directory'
vm_network=mock-network
copy_guest_artifacts() { record copy_guest_artifacts; }
log() { :; }
rm() { record rm "$@"; }
`+cleanup+"\n"+trap+"\n"+`exit "$RUN_STATUS"`, env...)
				calls := preflightCalls + preflightCalls + "copy_guest_artifacts\n"
				if !tc.dropDomain {
					calls += "dumpxml " + domainUUID + "\n"
					if keep != "1" {
						calls += removalCalls(domainUUID, tc.fallback)
					}
				}
				if !tc.dropBuilder {
					calls += "dumpxml " + builderUUID + "\n" + removalCalls(builderUUID, tc.fallback)
				}
				calls += "net-dhcp-leases mock-network\n"
				if keep != "1" {
					calls += "rm -rf mock work directory\n"
				}
				result.check(t, tc.status, "", calls)
			})
		}
	}
}

func TestLibvirtRunnerOwnershipWiring(t *testing.T) {
	runners, err := filepath.Glob("*/run-libvirt*.sh")
	if err != nil {
		t.Fatal(err)
	}
	if len(runners) != 11 {
		t.Fatalf("found %d runners, want nine bodies and two forwarders", len(runners))
	}
	bodies := 0
	for _, path := range runners {
		forwarder := path == "fedora/run-libvirt.sh" || path == "opensuse/run-libvirt.sh"
		if !forwarder {
			bodies++
		}
		t.Run(path, func(t *testing.T) {
			body := readHarnessFile(t, path)
			if forwarder {
				onlyMatch(t, body, `(?m)^exec "\$integration_dir/rocky/run-libvirt\.sh" "\$@"$`)
				return
			}
			onlyMatch(t, body, `(?m)^set -Eeuo pipefail$`)
			source := onlyMatch(t, body, `(?m)^\. "\$repo_dir/integration_tests/libvirt-domain\.sh"$`)
			mkdir := regexp.MustCompile(`(?m)^[\t ]*mkdir[\t ]+`).FindStringIndex(body)
			if mkdir == nil {
				t.Fatal("missing first mkdir")
			}
			identities := []string{`domain_uuid=$(new_domain_uuid "$domain_name")`}
			if path == "systemv/run-libvirt.sh" {
				identities = append(identities, `builder_uuid=$(new_domain_uuid "$domain_name-builder")`)
			}
			for _, identity := range identities {
				onlyMatch(t, body, `(?m)^`+regexp.QuoteMeta(identity)+`$`)
				at := strings.Index(body, identity)
				if at <= strings.Index(body, source) || at >= mkdir[0] {
					t.Fatalf("%s must follow sourcing the helper and precede the first mkdir", identity)
				}
			}

			// Resolve the actual array used by virt-install, or inspect the complete
			// continued command. Do not accept an unrelated --uuid elsewhere.
			flat := strings.ReplaceAll(body, "\\\n", " ")
			creations := regexp.MustCompile(`(?m)^[\t ]*(?:if ! )?virt-install[\t ]+[^\n]+`).FindAllString(flat, -1)
			if len(creations) != len(identities) {
				t.Fatalf("found %d creations, want %d", len(creations), len(identities))
			}
			for _, creation := range creations {
				if strings.Contains(creation, `"${virt_install_args[@]}"`) {
					args := onlyMatch(t, body, `(?ms)^virt_install_args=\(\n.*?^\)`)
					creation = strings.ReplaceAll(creation, `"${virt_install_args[@]}"`, args)
				}
				name, uuid := "$domain_name", "$domain_uuid"
				if strings.Contains(creation, `--name "$builder_domain"`) {
					name, uuid = "$builder_domain", "$builder_uuid"
				}
				if !strings.Contains(creation, `--name "`+name+`"`) || strings.Count(creation, "--uuid") != 1 || !strings.Contains(creation, `--uuid "`+uuid+`"`) {
					t.Fatalf("creation must explicitly bind %s to %s:\n%s", name, uuid, creation)
				}
			}
			if regexp.MustCompile(`\bvirsh(?:_command)?[^\n]*\b(?:create|define)\b`).MatchString(flat) {
				t.Fatal("unverified domain creation outside virt-install")
			}
			cleanup := shellFunction(t, body, "cleanup")
			uuid := "domain_uuid"
			if path == "systemv/run-libvirt.sh" {
				onlyMatch(t, cleanup, `(?m)^[\t ]*for uuid in "\$domain_uuid" "\$builder_uuid"; do$`)
				uuid = "uuid"
			}
			onlyMatch(t, cleanup, `(?m)^[\t ]*remove_owned_domain "\$`+uuid+`"$`)
			onlyMatch(t, body, `(?m)^trap cleanup EXIT$`)
			mutations := regexp.MustCompile(`(?:remove_owned_domain|virsh_command[\t ]+(?:destroy|undefine|shutdown))[\t ]+("[^"]*"|[^\t \n;|]+)`).FindAllStringSubmatch(flat, -1)
			for _, mutation := range mutations {
				arg := mutation[1]
				if arg != `"$domain_uuid"` && !(path == "systemv/run-libvirt.sh" && (arg == `"$builder_uuid"` || arg == `"$uuid"`)) {
					t.Fatalf("domain mutation must use an owned UUID: %s", mutation[0])
				}
			}
			if regexp.MustCompile(`\bvirsh[\t ]+[^\n]*\b(?:destroy|undefine|shutdown)\b`).MatchString(flat) {
				t.Fatal("domain mutation bypasses the shared helper")
			}
		})
	}
	if bodies != 9 {
		t.Fatalf("found %d runner bodies, want nine plus Fedora/openSUSE forwarders", bodies)
	}
}

func TestFedoraVMResourceDefaults(t *testing.T) {
	runner := readHarnessFile(t, "fedora/run-libvirt.sh")
	script := onlyMatch(t, runner, `(?m)^export VM_MEMORY_MIB=.*$`) + "\n" +
		onlyMatch(t, runner, `(?m)^export VM_VCPUS=.*$`) + "\n" +
		`printf '%s %s\n' "$VM_MEMORY_MIB" "$VM_VCPUS"`
	runShell(t, "bash", script).check(t, 0, "3072 4\n", "")
	runShell(t, "bash", script, "VM_MEMORY_MIB=4096", "VM_VCPUS=2").check(t, 0, "4096 2\n", "")
}

func TestOpenSUSEAppArmorAssertion(t *testing.T) {
	runner := readHarnessFile(t, "opensuse/run-libvirt.sh")
	assertion := onlyMatch(t, runner, `(?m)^export DISTRO_GUEST_ASSERTION=.*$`)
	grep := commandPath(t, "grep")
	for _, shell := range []string{"sh", "bash"} {
		for _, tc := range []struct {
			name, fs string
			present  bool
			status   int
		}{
			{"absent-xfs", "xfs", false, 1},
			{"absent-btrfs", "btrfs", false, 1},
			{"present-xfs", "xfs", true, 0},
			{"present-btrfs", "btrfs", true, 0},
			{"invalid-filesystem", "ext4", true, 1},
			{"filesystem-suffix", "xfs-extra", true, 1},
			{"missing-filesystem", "", true, 1},
		} {
			t.Run(shell+"/"+tc.name, func(t *testing.T) {
				apparmor, calls := 1, "test -d /sys/module/apparmor\n"
				if tc.present {
					apparmor = 0
					calls += "findmnt -n -o FSTYPE /\n"
				}
				// Deliberately no errexit: it would conceal the old semicolon false pass.
				result := runShell(t, shell, `
record() { printf '%s\n' "$*" >>"$CALLS"; }
test() {
	record test "$@"
	case "$#:$*" in
		'2:-d /sys/module/apparmor') return "$APPARMOR_STATUS" ;;
		*) return 99 ;;
	esac
}
findmnt() {
	record findmnt "$@"
	case "$#:$*" in
		'4:-n -o FSTYPE /') printf '%s\n' "$FSTYPE" ;;
		*) return 99 ;;
	esac
}
grep() { "$GREP" "$@"; }
unset DISTRO_GUEST_ASSERTION
`+assertion+"\n"+`eval "$DISTRO_GUEST_ASSERTION"`,
					"GREP="+grep, "FSTYPE="+tc.fs, fmt.Sprintf("APPARMOR_STATUS=%d", apparmor))
				result.check(t, tc.status, "", calls)
			})
		}
	}
}

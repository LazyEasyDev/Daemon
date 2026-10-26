package cloudhook_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

type cloudStartFixture struct {
	dir, caller, script, log, binDir, unitDir string
	env                                       []string
}

func newAWSStartFixture(t *testing.T) cloudStartFixture {
	t.Helper()
	return newCloudStartFixture(t, "aws")
}

func newCloudStartFixture(t *testing.T, provider string) cloudStartFixture {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("setup script fixtures require a native POSIX test host")
	}
	tempDir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(tempDir, "deployment with spaces")
	fixture := cloudStartFixture{
		dir:     dir,
		caller:  filepath.Join(dir, "caller"),
		script:  filepath.Join(dir, "cloud_hook", provider+"_start.sh"),
		log:     filepath.Join(dir, "commands.log"),
		binDir:  filepath.Join(dir, "shortcuts"),
		unitDir: filepath.Join(dir, "units"),
	}
	fakeBin := filepath.Join(dir, "fake-bin")
	for _, path := range []string{fixture.caller, fakeBin, fixture.binDir, fixture.unitDir, filepath.Join(dir, "cloud_hook")} {
		if err := os.MkdirAll(path, 0755); err != nil {
			t.Fatal(err)
		}
	}
	write := func(path, content string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(content), 0755); err != nil {
			t.Fatal(err)
		}
	}
	source, err := os.ReadFile(provider + "_start.sh")
	if err != nil {
		t.Fatal(err)
	}
	script := strings.NewReplacer(
		"daemon_link=/usr/bin/daemon", `daemon_link="$TEST_BIN_DIR/daemon"`,
		`daemon_link="$(cygpath -u "${WINDIR:-C:/Windows}")/System32/daemon.exe"`, `daemon_link="$TEST_BIN_DIR/daemon.exe"`,
		"unit_dir=/etc/systemd/system", `unit_dir="$TEST_UNIT_DIR"`,
	).Replace(string(source))
	if strings.Contains(script, "daemon_link=/usr/") ||
		strings.Contains(script, "unit_dir=/etc/") ||
		strings.Contains(script, "/System32/daemon.exe") {
		t.Fatal("test fixture did not isolate installation paths")
	}
	write(fixture.script, script)
	write(filepath.Join(fakeBin, "uname"), `#!/bin/sh
case "$1" in
  -s) printf '%s\n' "${TEST_OS:-Linux}" ;;
  -m) printf '%s\n' "${TEST_ARCH_NAME:-x86_64}" ;;
esac
`)
	write(filepath.Join(fakeBin, "id"), "#!/bin/sh\nprintf '%s\\n' \"${TEST_UID:-0}\"\n")
	write(filepath.Join(fakeBin, "go"), "#!/bin/sh\nexit 0\n")
	write(filepath.Join(fakeBin, "cygpath"), `#!/bin/sh
case "$1" in
  -u) printf '%s\n' "${2#C:}" ;;
  -w) printf 'C:%s\n' "$2" ;;
  *) exit 1 ;;
esac
`)
	write(filepath.Join(fakeBin, "powershell.exe"), `#!/bin/sh
set -eu
case "$*" in
  *WindowsPrincipal*)
    printf 'windows preflight\n' >> "$TEST_LOG"
    if [ "${TEST_WINDOWS_ADMIN:-1}" = 0 ]; then
      echo 'Open Git Bash as Administrator and run setup again.' >&2
      exit 1
    fi
    if [ "${TEST_WINDOWS_SCM_FAIL:-0}" = 1 ]; then
      echo 'Windows Service Control Manager unavailable.' >&2
      exit 1
    fi
    if [ -e "$TEST_UNIT_DIR/$DAEMON_HOOK_SERVICE.service" ]; then
      echo "$DAEMON_HOOK_SERVICE is already installed." >&2
      exit 1
    fi
    ;;
  *New-Item*)
    printf 'windows shortcut\n' >> "$TEST_LOG"
    if [ "${TEST_WINDOWS_LINK_FAIL:-0}" = 1 ]; then
      echo 'Windows shortcut creation failed.' >&2
      exit 1
    fi
    link=${DAEMON_LINK_PATH#C:}
    target=${DAEMON_TARGET_PATH#C:}
    if [ ! -L "$link" ]; then ln -s "$target" "$link"; fi
    case "$*" in
      *'Get-Command daemon'*) ;;
      *) echo 'Missing Windows command resolution check.' >&2; exit 1 ;;
    esac
    if [ "${TEST_WINDOWS_SHADOW:-0}" = 1 ]; then
      echo 'daemon resolves to another executable; check PATH.' >&2
      exit 1
    fi
    ;;
  *) echo 'Unexpected PowerShell command.' >&2; exit 1 ;;
esac
`)
	write(filepath.Join(fakeBin, "systemctl"), `#!/bin/sh
printf 'systemd check\n' >> "$TEST_LOG"
exit "${TEST_SYSTEMD_EXIT:-0}"
`)
	write(filepath.Join(fakeBin, "sudo"), `#!/bin/sh
printf 'sudo\n' >> "$TEST_LOG"
if [ "$1" = "-v" ]; then exit 0; fi
if [ "$1" = "--" ]; then shift; fi
exec "$@"
`)
	write(filepath.Join(dir, "fake-daemon"), `#!/bin/sh
printf 'daemon' >> "$TEST_LOG"
for argument do printf ' <%s>' "$argument" >> "$TEST_LOG"; done
printf '\n' >> "$TEST_LOG"
if [ "$1" = install ]; then
  touch "$TEST_UNIT_DIR/lz_lz_$2.service"
fi
if [ "$1" = start ] && [ "$2" = "$TEST_HOOK_SERVICE" ] && [ "${TEST_START_FAIL:-0}" = 1 ]; then
  echo 'hook start failed' >&2
  exit 23
fi
`)
	write(filepath.Join(dir, "build.sh"), `#!/bin/sh
set -eu
printf 'build daemon\n' >> "$TEST_LOG"
dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
mkdir -p "$dir/build"
target="$dir/build/daemon-${TEST_TARGET_OS:-linux}-${TEST_ARCH:-amd64}${TEST_EXTENSION:-}"
cp "$TEST_DAEMON" "$target"
chmod "${TEST_BUILD_MODE:-755}" "$dir/build" "$target"
umask > "$TEST_UMASK_FILE"
`)
	write(filepath.Join(dir, "cloud_hook", "build.sh"), `#!/bin/sh
set -eu
printf 'build hooks\n' >> "$TEST_LOG"
dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
mkdir -p "$dir/build"
target="$dir/build/${TEST_HOOK_BINARY}-${TEST_TARGET_OS:-linux}-${TEST_ARCH:-amd64}${TEST_EXTENSION:-}"
printf '#!/bin/sh\nexit 0\n' > "$target"
chmod "${TEST_BUILD_MODE:-755}" "$dir/build" "$target"
`)
	fixture.env = append(os.Environ(),
		"PATH="+fakeBin+string(os.PathListSeparator)+fixture.binDir+string(os.PathListSeparator)+os.Getenv("PATH"),
		"TEST_LOG="+fixture.log,
		"TEST_DAEMON="+filepath.Join(dir, "fake-daemon"),
		"TEST_BIN_DIR="+fixture.binDir,
		"TEST_UNIT_DIR="+fixture.unitDir,
		"TEST_HOOK_SERVICE="+provider+"Hook",
		"TEST_HOOK_BINARY="+provider+"_hook",
		"TEST_UMASK_FILE="+filepath.Join(dir, "build-umask"),
	)
	return fixture
}

func (fixture cloudStartFixture) run(args ...string) (string, error) {
	command := exec.Command("sh", append([]string{fixture.script}, args...)...)
	command.Dir = fixture.caller
	command.Env = fixture.env
	output, err := command.CombinedOutput()
	return string(output), err
}

func (fixture cloudStartFixture) commands(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile(fixture.log)
	if os.IsNotExist(err) {
		return ""
	}
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestCloudStartFindsRepositoryFromEitherDirectory(t *testing.T) {
	for _, provider := range []string{"aws", "azure"} {
		for _, directory := range []string{"root", "cloud_hook"} {
			t.Run(provider+"/"+directory, func(t *testing.T) {
				fixture := newCloudStartFixture(t, provider)
				if directory == "root" {
					fixture.caller = fixture.dir
					fixture.script = "./cloud_hook/" + provider + "_start.sh"
				} else {
					fixture.caller = filepath.Join(fixture.dir, "cloud_hook")
					fixture.script = "./" + provider + "_start.sh"
				}
				if output, err := fixture.run(); err != nil {
					t.Fatalf("setup failed from %s: %v\n%s", directory, err, output)
				}
				want := filepath.Join(fixture.dir, "build", "daemon-linux-amd64")
				if target, err := os.Readlink(filepath.Join(fixture.binDir, "daemon")); err != nil || target != want {
					t.Fatalf("shortcut = %q, error = %v; want %q", target, err, want)
				}
			})
		}
	}
}

func TestAWSStartInstallsShortcutAndHook(t *testing.T) {
	for _, arch := range []string{"amd64", "arm64"} {
		t.Run(arch, func(t *testing.T) {
			fixture := newAWSStartFixture(t)
			if arch == "arm64" {
				fixture.env = append(fixture.env, "TEST_ARCH_NAME=aarch64", "TEST_ARCH=arm64", "TEST_UID=1000")
			}
			output, err := fixture.run()
			if err != nil {
				t.Fatalf("script failed: %v\n%s", err, output)
			}
			physicalDir, err := filepath.EvalSymlinks(fixture.dir)
			if err != nil {
				t.Fatal(err)
			}
			target := filepath.Join(physicalDir, "build", "daemon-linux-"+arch)
			link, err := os.Readlink(filepath.Join(fixture.binDir, "daemon"))
			if err != nil || link != target {
				t.Fatalf("shortcut = %q, error = %v; want %q", link, err, target)
			}
			commands := fixture.commands(t)
			hook := filepath.Join(physicalDir, "cloud_hook", "build", "aws_hook-linux-"+arch)
			for _, want := range []string{
				"build daemon\nbuild hooks\n",
				"daemon <install> <awsHook> <" + hook + ">",
				"daemon <start> <awsHook>",
			} {
				if !strings.Contains(commands, want) {
					t.Errorf("missing %q in commands:\n%s", want, commands)
				}
			}
			if strings.Count(commands, "daemon <install>") != 1 {
				t.Fatal("setup must install only the AWS hook")
			}
			if !strings.Contains(output, "does not create that AWS hook") {
				t.Fatal("missing cloud prerequisite warning")
			}
		})
	}
}

func TestAWSStartRejectsUnsafeOrUnsupportedSetup(t *testing.T) {
	for _, name := range []string{"non-linux", "unsupported CPU", "no systemd", "existing shortcut", "existing hook"} {
		t.Run(name, func(t *testing.T) {
			fixture := newAWSStartFixture(t)
			switch name {
			case "non-linux":
				fixture.env = append(fixture.env, "TEST_OS=Darwin")
			case "unsupported CPU":
				fixture.env = append(fixture.env, "TEST_ARCH_NAME=mips")
			case "no systemd":
				fixture.env = append(fixture.env, "TEST_SYSTEMD_EXIT=1")
			case "existing shortcut":
				if err := os.MkdirAll(fixture.binDir, 0755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(fixture.binDir, "daemon"), []byte("unrelated"), 0755); err != nil {
					t.Fatal(err)
				}
			case "existing hook":
				if err := os.WriteFile(filepath.Join(fixture.unitDir, "lz_lz_awsHook.service"), nil, 0644); err != nil {
					t.Fatal(err)
				}
			}
			output, err := fixture.run()
			if err == nil {
				t.Fatalf("accepted invalid setup: %s", output)
			}
			if name == "no systemd" && !strings.Contains(output, "A running, accessible systemd service manager is required.") {
				t.Fatalf("missing systemd prerequisite error: %s", output)
			}
			if strings.Contains(fixture.commands(t), "build daemon") {
				t.Fatal("built binaries before preflight failed")
			}
		})
	}
}

func TestAWSStartShortcutWorksInNewShell(t *testing.T) {
	fixture := newAWSStartFixture(t)
	if output, err := fixture.run(); err != nil {
		t.Fatalf("setup failed: %v\n%s", err, output)
	}
	command := exec.Command("sh", "-c", "daemon status awsHook")
	command.Dir = fixture.caller
	command.Env = append(os.Environ(), "PATH="+fixture.binDir+string(os.PathListSeparator)+os.Getenv("PATH"), "TEST_LOG="+fixture.log)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("global command failed in a new shell: %v\n%s", err, output)
	}
	if !strings.Contains(fixture.commands(t), "daemon <status> <awsHook>") {
		t.Fatal("new shell did not invoke the deployed daemon shortcut")
	}
}

func TestAWSStartRejectsShadowedGlobalCommand(t *testing.T) {
	fixture := newAWSStartFixture(t)
	shadow := filepath.Join(fixture.dir, "fake-bin", "daemon")
	if err := os.WriteFile(shadow, []byte("#!/bin/sh\nexit 0\n"), 0755); err != nil {
		t.Fatal(err)
	}
	output, err := fixture.run()
	if err == nil || !strings.Contains(output, "check the privileged PATH") {
		t.Fatalf("output = %q, error = %v", output, err)
	}
	if strings.Contains(fixture.commands(t), "daemon <install>") {
		t.Fatal("installed services before verifying the global command")
	}
}

func TestAWSStartRejectsArguments(t *testing.T) {
	for _, args := range [][]string{
		{"worker"},
		{"worker", "/opt/app", "--config", "config.toml"},
		{"--help", "extra"},
		{"--unknown"},
	} {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			fixture := newAWSStartFixture(t)
			output, err := fixture.run(args...)
			if err == nil || !strings.Contains(output, "Usage: sh ./cloud_hook/aws_start.sh") {
				t.Fatalf("output = %q, error = %v", output, err)
			}
			if commands := fixture.commands(t); commands != "" {
				t.Fatalf("setup performed work despite invalid arguments:\n%s", commands)
			}
		})
	}
}

func TestAWSStartHelpDoesNotPerformSetup(t *testing.T) {
	fixture := newAWSStartFixture(t)
	output, err := fixture.run("--help")
	if err != nil || !strings.Contains(output, "Install your applications separately") {
		t.Fatalf("output = %q, error = %v", output, err)
	}
	if commands := fixture.commands(t); commands != "" {
		t.Fatalf("help performed setup:\n%s", commands)
	}
}

func TestAWSStartReportsHookStartFailure(t *testing.T) {
	fixture := newAWSStartFixture(t)
	fixture.env = append(fixture.env, "TEST_START_FAIL=1")
	output, err := fixture.run()
	if err == nil || !strings.Contains(output, "hook start failed") {
		t.Fatalf("output = %q, error = %v", output, err)
	}
	if strings.Contains(output, "Installed daemon shortcut:") {
		t.Fatal("reported success after hook failed to start")
	}
}

func TestAWSStartEnforcesBuildPermissions(t *testing.T) {
	for _, mode := range []string{"700", "777", "1755"} {
		t.Run(mode, func(t *testing.T) {
			fixture := newAWSStartFixture(t)
			fixture.env = append(fixture.env, "TEST_BUILD_MODE="+mode)
			privateFile := filepath.Join(fixture.dir, "private-config")
			if err := os.WriteFile(privateFile, []byte("keep private"), 0600); err != nil {
				t.Fatal(err)
			}
			command := exec.Command("sh", "-c", `umask 000; exec sh "$1"`, "sh", fixture.script)
			command.Dir = fixture.caller
			command.Env = fixture.env
			if output, err := command.CombinedOutput(); err != nil {
				t.Fatalf("setup failed: %v\n%s", err, output)
			}
			for _, relative := range []string{
				"build", "cloud_hook/build", "build/daemon-linux-amd64", "cloud_hook/build/aws_hook-linux-amd64",
			} {
				info, err := os.Stat(filepath.Join(fixture.dir, relative))
				if err != nil {
					t.Fatal(err)
				}
				if info.Mode().Perm() != 0755 || info.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0 {
					t.Errorf("%s mode = %v, want 755 without special bits", relative, info.Mode())
				}
			}
			data, err := os.ReadFile(filepath.Join(fixture.dir, "build-umask"))
			if err != nil {
				t.Fatal(err)
			}
			mask := strings.TrimSpace(string(data))
			if mask != "0022" && mask != "022" {
				t.Fatalf("build umask = %q, want 022", mask)
			}
			info, err := os.Stat(privateFile)
			if err != nil || info.Mode().Perm() != 0600 {
				t.Fatalf("unrelated file permissions changed: info = %v, error = %v", info, err)
			}
		})
	}
}

func TestAWSStartReportsPermissionFailure(t *testing.T) {
	fixture := newAWSStartFixture(t)
	path, err := exec.LookPath("chmod")
	if err != nil {
		t.Fatal(err)
	}
	fixture.env = append(fixture.env, "TEST_REAL_CHMOD="+path)
	// Allow build permissions to succeed; fail only the deployment chmod.
	content := "#!/bin/sh\nif [ \"$1\" = u=rwx,go=rx,a-s,a-t ]; then echo 'chmod failed' >&2; exit 1; fi\nexec \"$TEST_REAL_CHMOD\" \"$@\"\n"
	if err := os.WriteFile(filepath.Join(fixture.dir, "fake-bin", "chmod"), []byte(content), 0755); err != nil {
		t.Fatal(err)
	}
	output, err := fixture.run()
	if err == nil || !strings.Contains(output, "chmod failed") {
		t.Fatalf("output = %q, error = %v", output, err)
	}
	if strings.Contains(fixture.commands(t), "daemon <install>") {
		t.Fatal("registered services after setting permissions failed")
	}
}

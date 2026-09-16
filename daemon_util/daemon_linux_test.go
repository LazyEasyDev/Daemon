//go:build linux

package daemon_util

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"text/template"
	"time"
)

func TestLinuxTemplatesConfigureStopTimeout(t *testing.T) {
	data := struct {
		Name, Description, Path, Args, WorkingDirectory string
		StopTimeoutSeconds                              int64
	}{"worker", "worker", "/opt/worker", "", "/opt", 45}
	funcs := template.FuncMap{
		"shellQuote":         shellQuote,
		"systemdQuote":       systemdQuote,
		"systemdDescription": systemdDescription,
		"systemdPathValue":   systemdPathValue,
		"upstartQuote":       upstartQuote,
	}
	tests := []struct {
		name   string
		source string
		want   string
	}{
		{name: "systemd", source: defaultSystemDConfig, want: "TimeoutStopSec=45s"},
		{name: "OpenRC", source: defaultOpenRCConfig, want: `retry="TERM/45/KILL/5"`},
		{name: "OpenWrt", source: defaultOpenWrtConfig, want: "STOP_TIMEOUT=45"},
		{name: "Upstart", source: defaultUpstartConfig, want: "kill timeout 45"},
		{name: "System V", source: defaultSystemVConfig, want: "stop_timeout=45"},
		{name: "Buildroot", source: defaultBuildrootConfig, want: "STOP_TIMEOUT=45"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			tpl, err := template.New(test.name).Funcs(funcs).Parse(test.source)
			if err != nil {
				t.Fatal(err)
			}
			var output bytes.Buffer
			if err := tpl.Execute(&output, data); err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(output.String(), test.want) {
				t.Fatalf("rendered template does not contain %q", test.want)
			}
		})
	}
}

func TestSystemDTemplateDoesNotRestartExecFailures(t *testing.T) {
	want := "Restart=on-failure\nRestartPreventExitStatus=203\nRestartSec=20s"
	if !strings.Contains(defaultSystemDConfig, want) {
		t.Fatalf("systemd template does not contain %q", want)
	}
}

func TestLinuxTemplatesConfigureWorkingDirectory(t *testing.T) {
	funcs := template.FuncMap{
		"shellQuote":         shellQuote,
		"systemdQuote":       systemdQuote,
		"systemdDescription": systemdDescription,
		"systemdPathValue":   systemdPathValue,
		"upstartQuote":       upstartQuote,
	}
	tests := []struct {
		name             string
		source           string
		workingDirectory string
		wants            []string
	}{
		{name: "systemd", source: defaultSystemDConfig, workingDirectory: "/opt/worker % files", wants: []string{
			"Description=worker",
			"ExecStart=" + systemdQuote("/opt/worker % files/worker"),
			"WorkingDirectory=/opt/worker %% files",
		}},
		{name: "OpenRC", source: defaultOpenRCConfig, workingDirectory: "/opt/worker's % files", wants: []string{"directory=" + shellQuote("/opt/worker's % files")}},
		{name: "OpenWrt", source: defaultOpenWrtConfig, workingDirectory: "/opt/worker's % files", wants: []string{
			"WORKING_DIRECTORY=" + shellQuote("/opt/worker's % files"),
			`procd_set_param command /bin/sh -c 'cd "$1" && shift && exec "$@"' sh "$WORKING_DIRECTORY" "$PROG" 'argument with spaces'`,
		}},
		{name: "runit", source: defaultRunitConfig, workingDirectory: "/opt/worker's % files", wants: []string{
			"cd " + shellQuote("/opt/worker's % files") + " || exit 111",
			"exec chpst -P " + shellQuote("/opt/worker's % files/worker") + " 'argument with spaces'",
		}},
		{name: "Upstart", source: defaultUpstartConfig, workingDirectory: "/opt/worker's % files", wants: []string{"chdir " + upstartQuote("/opt/worker's % files")}},
		{name: "System V", source: defaultSystemVConfig, workingDirectory: "/opt/worker's % files", wants: []string{
			"working_directory=" + shellQuote("/opt/worker's % files"),
			`cd "$working_directory" || exit 5`,
		}},
		{name: "Buildroot", source: defaultBuildrootConfig, workingDirectory: "/opt/worker's % files", wants: []string{
			"WORKING_DIRECTORY=" + shellQuote("/opt/worker's % files"),
			`if ! cd "$WORKING_DIRECTORY"; then`,
		}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			data := struct {
				Name, Description, Path, Args, WorkingDirectory string
				StopTimeoutSeconds                              int64
			}{"worker", "worker", test.workingDirectory + "/worker", shellQuoteArgs([]string{"argument with spaces"}), test.workingDirectory, 45}
			tpl, err := template.New(test.name).Funcs(funcs).Parse(test.source)
			if err != nil {
				t.Fatal(err)
			}
			var output bytes.Buffer
			if err := tpl.Execute(&output, data); err != nil {
				t.Fatal(err)
			}
			for _, want := range test.wants {
				if !strings.Contains(output.String(), want) {
					t.Fatalf("rendered template does not contain %q", want)
				}
			}
		})
	}
}

func TestSystemDPathValueEscapesSpecifiers(t *testing.T) {
	got := systemdPathValue("/opt/worker % files")
	want := "/opt/worker %% files"
	if got != want {
		t.Fatalf("systemdPathValue() = %q, want %q", got, want)
	}
}

func TestSystemDDescriptionPreservesTextAndEscapesSpecifiers(t *testing.T) {
	tests := []struct {
		name  string
		value string
		want  string
	}{
		{name: "plain", value: "worker service", want: "worker service"},
		{name: "specifier", value: "worker 100% service", want: "worker 100%% service"},
		{name: "quotes and backslash", value: `worker "quoted" \ path`, want: `worker "quoted" \ path`},
		{name: "trailing backslash", value: `worker\`, want: "worker\\ "},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := systemdDescription(test.value); got != test.want {
				t.Fatalf("systemdDescription() = %q, want %q", got, test.want)
			}
		})
	}
}

func TestValidateSystemDExecutablePath(t *testing.T) {
	if err := validateSystemDExecutablePath("/opt/worker % files/worker"); err != nil {
		t.Fatalf("safe path rejected: %v", err)
	}

	for _, path := range []string{
		"/opt/worker$release/worker",
		"/opt/worker's/worker",
		`/opt/worker"quote/worker`,
		`/opt/worker\config/worker`,
		"/opt/worker\nExecStart=/bin/false",
		"/opt/worker\tconfig/worker",
		"/opt/worker\x7fconfig/worker",
		"/opt/worker /worker",
	} {
		if err := validateSystemDExecutablePath(path); !errors.Is(err, ErrInvalidExecutablePath) {
			t.Errorf("validateSystemDExecutablePath(%q) error = %v, want ErrInvalidExecutablePath", path, err)
		}
	}
}

func TestOpenWrtLauncherPreservesWorkingDirectoryAndArguments(t *testing.T) {
	const launchScript = `cd "$1" && shift && exec "$@"`
	if !strings.Contains(defaultOpenWrtConfig, shellQuote(launchScript)) {
		t.Fatal("OpenWrt config does not contain the tested positional launcher")
	}

	workingDirectory := t.TempDir()
	arguments := []string{"", "argument with spaces", "argument's quote", `literal;$(not-run)`, "%value", "-leading"}
	inspectScript := `printf 'cwd=<%s>\ncount=<%s>\n' "$PWD" "$#"; for argument do printf 'arg=<%s>\n' "$argument"; done`
	commandArguments := []string{"-c", launchScript, "sh", workingDirectory, "/bin/sh", "-c", inspectScript, "app"}
	commandArguments = append(commandArguments, arguments...)
	output, err := exec.Command("/bin/sh", commandArguments...).CombinedOutput()
	if err != nil {
		t.Fatalf("run OpenWrt launcher: %v\n%s", err, output)
	}

	want := "cwd=<" + workingDirectory + ">\ncount=<6>\n"
	for _, argument := range arguments {
		want += "arg=<" + argument + ">\n"
	}
	if string(output) != want {
		t.Fatalf("launcher output = %q, want %q", output, want)
	}
}

func TestOpenWrtRespawnsWithoutRetryLimit(t *testing.T) {
	if !strings.Contains(defaultOpenWrtConfig, "procd_set_param respawn 0 30 0") {
		t.Fatal("OpenWrt config must respawn after 30 seconds without a retry limit")
	}
	if strings.Contains(defaultOpenWrtConfig, "procd_set_param respawn 0 30 10000") {
		t.Fatal("OpenWrt config still contains the old finite retry limit")
	}
}

func TestOpenWrtWaitsForServiceStop(t *testing.T) {
	for _, setting := range []string{
		`procd_set_param term_timeout "$STOP_TIMEOUT"`,
		`service_stopped() {`,
		`while procd_running "$DAEMON"; do`,
		`if [ "$elapsed" -ge $((STOP_TIMEOUT + 5)) ]; then`,
		`return 1`,
	} {
		if !strings.Contains(defaultOpenWrtConfig, setting) {
			t.Fatalf("OpenWrt config does not contain %q", setting)
		}
	}
}

func TestOpenRCRespawnsWithoutRetryLimit(t *testing.T) {
	for _, setting := range []string{
		"supervisor=supervise-daemon",
		"stopgroup=true",
		"rc_cgroup_cleanup=yes",
		"respawn_delay=30",
		"respawn_max=0",
	} {
		if !strings.Contains(defaultOpenRCConfig, setting) {
			t.Fatalf("OpenRC config does not contain %q", setting)
		}
	}
	if strings.Contains(defaultOpenRCConfig, "command_background=yes") {
		t.Fatal("OpenRC config must leave the application in the foreground")
	}
	for _, redundant := range []string{"stop_pre()", "stop_post()", "daemon_stop_process_group", `kill -KILL`} {
		if strings.Contains(defaultOpenRCConfig, redundant) {
			t.Fatalf("OpenRC config contains redundant manual stop logic %q", redundant)
		}
	}
}

func TestOpenRCRunlevelCommandsTargetDefault(t *testing.T) {
	service := &openRCRecord{name: "worker"}
	for _, action := range []string{"add", "delete"} {
		got := service.runlevelCommand(action).Args
		want := []string{"rc-update", action, "worker", "default"}
		if !slices.Equal(got, want) {
			t.Errorf("runlevelCommand(%q).Args = %q, want %q", action, got, want)
		}
	}
}

func TestOpenRCStatus(t *testing.T) {
	tests := []struct {
		name           string
		status         string
		exitCode       int
		wantState      openRCServiceState
		wantRunning    bool
		wantStartable  bool
		wantStoppable  bool
		wantRecognized bool
	}{
		{name: "running", status: "status: started", wantState: openRCServiceStarted, wantRunning: true, wantStoppable: true, wantRecognized: true},
		{name: "stopped", status: "status: stopped", exitCode: 3, wantState: openRCServiceStopped, wantStartable: true, wantRecognized: true},
		{name: "stopping", status: "status: stopping", exitCode: 4, wantState: openRCServiceStopping, wantRunning: true, wantStoppable: true, wantRecognized: true},
		{name: "starting", status: "status: starting", exitCode: 8, wantState: openRCServiceStarting, wantRunning: true, wantStoppable: true, wantRecognized: true},
		{name: "inactive", status: "status: inactive", exitCode: 16, wantState: openRCServiceInactive, wantStartable: true, wantStoppable: true, wantRecognized: true},
		{name: "crashed", status: "status: crashed", exitCode: 32, wantState: openRCServiceCrashed, wantStoppable: true, wantRecognized: true},
		{name: "unsupervised", status: "status: unsupervised", exitCode: 64, wantState: openRCServiceUnsupervised, wantStoppable: true, wantRecognized: true},
		{name: "query failure", status: "permission denied", exitCode: 1},
		{name: "mismatched output", status: "status: stopped", exitCode: 32},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			state, recognized := openRCStatus(test.status, test.exitCode)
			if state != test.wantState || state.running() != test.wantRunning || state.startable() != test.wantStartable || state.stoppable() != test.wantStoppable || recognized != test.wantRecognized {
				t.Fatalf("openRCStatus() = (%v, %v, %v, %v, %v), want (%v, %v, %v, %v, %v)", state, state.running(), state.startable(), state.stoppable(), recognized, test.wantState, test.wantRunning, test.wantStartable, test.wantStoppable, test.wantRecognized)
			}
		})
	}
}

func TestRunitStatus(t *testing.T) {
	tests := []struct {
		status         string
		exitCode       int
		wantState      runitServiceState
		wantRecognized bool
	}{
		{status: "run: /var/service/worker: (pid 42) 5s", wantState: runitServiceRun, wantRecognized: true},
		{status: "finish: /var/service/worker: (pid 43) 1s", wantState: runitServiceFinish, wantRecognized: true},
		{status: "down: /var/service/worker: 3s, normally up", wantState: runitServiceDown, wantRecognized: true},
		{status: "down: /var/service/worker: 3s, normally down", wantState: runitServiceDown, wantRecognized: true},
		{status: "fail: /var/service/worker: unable to change to service directory"},
		{status: "down: /var/service/worker: 3s, normally up", exitCode: 1},
	}

	for _, test := range tests {
		state, recognized := runitStatus(test.status, test.exitCode)
		if state != test.wantState || recognized != test.wantRecognized {
			t.Errorf("runitStatus(%q, %d) = (%v, %v), want (%v, %v)", test.status, test.exitCode, state, recognized, test.wantState, test.wantRecognized)
		}
	}
}

func TestRunitStopEligibility(t *testing.T) {
	tests := []struct {
		name          string
		status        string
		exitCode      int
		wantStoppable bool
	}{
		{name: "waiting to respawn", status: "down: /var/service/worker: 0s, normally up, want up", wantStoppable: true},
		{name: "down but enabled", status: "down: /var/service/worker: 3s, normally up", wantStoppable: true},
		{name: "normally down", status: "down: /var/service/worker: 3s", wantStoppable: true},
		{name: "running", status: "run: /var/service/worker: (pid 42) 5s", wantStoppable: true},
		{name: "finishing", status: "finish: /var/service/worker: (pid 43) 1s", wantStoppable: true},
		{name: "unknown status", status: "fail: /var/service/worker: unable to open supervise/ok"},
		{name: "query failure", status: "down: /var/service/worker: 0s, normally up, want up", exitCode: 1},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			state, _ := runitStatus(test.status, test.exitCode)
			if got := state.stoppable(); got != test.wantStoppable {
				t.Fatalf("runitStatus(%q, %d).stoppable() = %v, want %v", test.status, test.exitCode, got, test.wantStoppable)
			}
		})
	}
}

func TestRunitUnsupervised(t *testing.T) {
	for _, status := range []string{
		"fail: /etc/sv/worker: unable to open supervise/ok: file does not exist",
		"warning: /etc/sv/worker: unable to open supervise/control: file does not exist",
	} {
		if !runitUnsupervised(status, 1) {
			t.Errorf("runitUnsupervised(%q, 1) = false, want true", status)
		}
	}
	if runitUnsupervised("fail: /etc/sv/worker: permission denied", 1) {
		t.Fatal("permission failure reported as unsupervised")
	}
}

func TestRunitCommands(t *testing.T) {
	service := &runitRecord{name: "worker"}
	if err := service.SetStopTimeout(45 * time.Second); err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name string
		got  []string
		want []string
	}{
		{name: "status", got: service.statusCommand().Args, want: []string{"sv", "status", "/var/service/worker"}},
		{name: "start", got: service.startCommand().Args, want: []string{"sv", "-w", "7", "start", "/var/service/worker"}},
		{name: "stop", got: service.stopCommand().Args, want: []string{"sv", "-w", "45", "force-stop", "/var/service/worker"}},
		{name: "shutdown", got: service.shutdownCommand().Args, want: []string{"sv", "-w", "45", "force-shutdown", "/etc/sv/worker"}},
	}

	for _, test := range tests {
		if !slices.Equal(test.got, test.want) {
			t.Errorf("%s command = %q, want %q", test.name, test.got, test.want)
		}
	}
}

func TestRunitUsesProcessGroupControl(t *testing.T) {
	for _, setting := range []string{
		"exec chpst -P ",
	} {
		if !strings.Contains(defaultRunitConfig, setting) {
			t.Fatalf("runit run template does not contain %q", setting)
		}
	}
	for _, setting := range []string{
		`pid=$(cat "$pidfile") || exit 1`,
		`process_after_name=${process_stat##*) }`,
		`[ "$3" = "$pid" ] || exit 1`,
		`kill -{{.Signal}} "-$pid"`,
	} {
		if !strings.Contains(defaultRunitControlConfig, setting) {
			t.Fatalf("runit control template does not contain %q", setting)
		}
	}
}

func TestReadRunitStopTimeout(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stop-timeout")
	if got := readRunitStopTimeout(path, 600); got != 600 {
		t.Fatalf("missing stop timeout = %d, want 600", got)
	}
	if err := os.WriteFile(path, []byte("45\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if got := readRunitStopTimeout(path, 600); got != 45 {
		t.Fatalf("stored stop timeout = %d, want 45", got)
	}
	if err := os.WriteFile(path, []byte("invalid\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if got := readRunitStopTimeout(path, 600); got != 600 {
		t.Fatalf("invalid stop timeout = %d, want 600", got)
	}
}

func TestUpstartRespawnsWithoutRetryLimit(t *testing.T) {
	if !strings.Contains(defaultUpstartConfig, "respawn limit 0 5") {
		t.Fatal("Upstart config must respawn without a retry limit")
	}
}

func TestUpstartCommandsUseInitctl(t *testing.T) {
	record := &upstartRecord{name: "worker"}
	for _, action := range []string{"status", "start", "stop"} {
		command := record.command(action)
		if command.Path != upstartCommandPath {
			t.Errorf("%s command path = %q, want %q", action, command.Path, upstartCommandPath)
		}
		wantArgs := strings.Join([]string{upstartCommandPath, action, "worker"}, "\x00")
		if gotArgs := strings.Join(command.Args, "\x00"); gotArgs != wantArgs {
			t.Errorf("%s command args = %q, want %q", action, command.Args, []string{upstartCommandPath, action, "worker"})
		}
	}
}

func TestUpstartStatus(t *testing.T) {
	tests := []struct {
		status         string
		exitCode       int
		wantRunning    bool
		wantRecognized bool
	}{
		{status: "worker start/starting", wantRunning: true, wantRecognized: true},
		{status: "worker start/pre-start, process 101", wantRunning: true, wantRecognized: true},
		{status: "worker start/spawned, process 102", wantRunning: true, wantRecognized: true},
		{status: "worker start/post-start, process 103", wantRunning: true, wantRecognized: true},
		{status: "worker start/running, process 104", wantRunning: true, wantRecognized: true},
		{status: "worker stop/stopping, process 104", wantRunning: true, wantRecognized: true},
		{status: "worker stop/waiting", wantRecognized: true},
		{status: "other start/running, process 104"},
		{status: "worker stop/waiting", exitCode: 1},
	}

	for _, test := range tests {
		gotRunning, gotRecognized := upstartStatus("worker", test.status, test.exitCode)
		if gotRunning != test.wantRunning || gotRecognized != test.wantRecognized {
			t.Errorf("upstartStatus(%q, %d) = (%v, %v), want (%v, %v)", test.status, test.exitCode, gotRunning, gotRecognized, test.wantRunning, test.wantRecognized)
		}
	}
}

func TestGeneratedInitStatus(t *testing.T) {
	tests := []struct {
		name           string
		status         string
		exitCode       int
		wantRunning    bool
		wantRecognized bool
	}{
		{name: "Buildroot running", status: "worker is running (pid 42)", wantRunning: true, wantRecognized: true},
		{name: "Buildroot stopped", status: "worker is stopped", exitCode: 3, wantRecognized: true},
		{name: "Buildroot failure", status: "permission denied", exitCode: 1},
		{name: "System V running", status: "worker (pid  42) is running...", wantRunning: true, wantRecognized: true},
		{name: "System V stopped", status: "worker is stopped", exitCode: 3, wantRecognized: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var running, recognized bool
			if strings.HasPrefix(test.name, "Buildroot") {
				running, recognized = buildrootStatus(test.status, test.exitCode)
			} else {
				running, recognized = systemVStatus("worker", test.status, test.exitCode)
			}
			if running != test.wantRunning || recognized != test.wantRecognized {
				t.Fatalf("status = (%v, %v), want (%v, %v)", running, recognized, test.wantRunning, test.wantRecognized)
			}
		})
	}
}

func TestSystemDStatus(t *testing.T) {
	tests := []struct {
		status         string
		wantRunning    bool
		wantRecognized bool
	}{
		{status: "active", wantRunning: true, wantRecognized: true},
		{status: "activating", wantRunning: true, wantRecognized: true},
		{status: "reloading", wantRunning: true, wantRecognized: true},
		{status: "refreshing", wantRunning: true, wantRecognized: true},
		{status: "inactive", wantRecognized: true},
		{status: "failed", wantRecognized: true},
		{status: "deactivating", wantRunning: true, wantRecognized: true},
		{status: "access denied"},
	}

	for _, test := range tests {
		gotRunning, gotRecognized := systemDStatus(test.status)
		if gotRunning != test.wantRunning || gotRecognized != test.wantRecognized {
			t.Errorf("systemDStatus(%q) = (%v, %v), want (%v, %v)", test.status, gotRunning, gotRecognized, test.wantRunning, test.wantRecognized)
		}
	}
}

func TestSystemDStopsControlGroup(t *testing.T) {
	if !strings.Contains(defaultSystemDConfig, "KillMode=control-group") {
		t.Fatal("systemd config must stop the entire service control group")
	}
}

func TestOpenWrtStatusActive(t *testing.T) {
	tests := []struct {
		status         string
		exitCode       int
		wantState      openWrtServiceState
		wantRunning    bool
		wantStartable  bool
		wantStoppable  bool
		wantRecognized bool
	}{
		{status: "running", wantState: openWrtServiceRunning, wantRunning: true, wantStoppable: true, wantRecognized: true},
		{status: "running (1/2)", wantState: openWrtServiceRunning, wantRunning: true, wantStoppable: true, wantRecognized: true},
		{status: "active with no instances", wantState: openWrtServiceRunning, wantRunning: true, wantStoppable: true, wantRecognized: true},
		{status: "inactive", exitCode: 3, wantState: openWrtServiceInactive, wantStartable: true, wantRecognized: true},
		{status: "not running", exitCode: 5, wantState: openWrtServiceNotRunning, wantStartable: true, wantStoppable: true, wantRecognized: true},
		{status: "not running", exitCode: 3},
		{status: "not running", exitCode: 1},
		{status: "unknown instance", exitCode: 4},
	}

	for _, test := range tests {
		gotState, gotRecognized := openWrtStatus(test.status, test.exitCode)
		if gotState != test.wantState || gotState.running() != test.wantRunning || gotState.startable() != test.wantStartable || gotState.stoppable() != test.wantStoppable || gotRecognized != test.wantRecognized {
			t.Errorf("openWrtStatus(%q, %d) = (%v, %v, %v, %v, %v), want (%v, %v, %v, %v, %v)", test.status, test.exitCode, gotState, gotState.running(), gotState.startable(), gotState.stoppable(), gotRecognized, test.wantState, test.wantRunning, test.wantStartable, test.wantStoppable, test.wantRecognized)
		}
	}
}

func TestGeneratedLinuxInitUsesPIDStarttimeIdentity(t *testing.T) {
	tests := []struct {
		name         string
		source       string
		identityFile string
		pidFile      string
	}{
		{name: "Buildroot", source: defaultBuildrootConfig, identityFile: `IDENTITYFILE=${PIDFILE}.identity`, pidFile: "$PIDFILE"},
		{name: "System V", source: defaultSystemVConfig, identityFile: `identityfile="${pidfile}.identity"`, pidFile: "$pidfile"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			for _, setting := range []string{
				test.identityFile,
				`process_starttime() {`,
				`process_after_name=${process_stat##*) }`,
				`[ "$#" -ge 20 ] || return 1`,
				`[ "$1" != Z ] || return 1`,
				`shift 19`,
				`read_identity() {`,
				`record_identity() {`,
				`printf '%s %s\n' "$pid" "$identity_starttime"`,
				`current_starttime=$(process_starttime "$pid")`,
				`[ "$current_starttime" = "$identity_starttime" ]`,
			} {
				if !strings.Contains(test.source, setting) {
					t.Fatalf("template does not contain %q", setting)
				}
			}
			if strings.Contains(test.source, `printf '%s %s\n' "$pid" "$identity_starttime" > `+test.pidFile) {
				t.Fatal("template stores the start time in the numeric PID file")
			}
		})
	}
}

func TestBuildrootValidatesIdentityBeforeSignals(t *testing.T) {
	for _, command := range []string{
		`is_expected_executable() {`,
		`start-stop-daemon -K -t -q -p "$PIDFILE" -x "$DAEMON"`,
		`signal_process() {`,
		`is_running || return 1`,
		`start-stop-daemon -K -q -s "$process_signal" -p "$PIDFILE"`,
		`signal_process TERM`,
		`signal_process KILL`,
	} {
		if !strings.Contains(defaultBuildrootConfig, command) {
			t.Fatalf("Buildroot config does not contain %q", command)
		}
	}
	for _, command := range []string{
		`start-stop-daemon -K -q -p "$PIDFILE" -x "$DAEMON"`,
		`start-stop-daemon -K -q -s KILL -p "$PIDFILE" -x "$DAEMON"`,
		`is_pid_running() {`,
		`running (unverified pid`,
		`kill -0 "$pid"`,
		`kill -KILL "$pid"`,
	} {
		if strings.Contains(defaultBuildrootConfig, command) {
			t.Fatalf("Buildroot config still contains obsolete process check %q", command)
		}
	}
}

func TestBuildrootDirectRestartDoesNotAddDelay(t *testing.T) {
	restartStart := strings.Index(defaultBuildrootConfig, "\trestart)\n")
	if restartStart < 0 {
		t.Fatal("Buildroot restart action is missing")
	}
	statusOffset := strings.Index(defaultBuildrootConfig[restartStart:], "\n\tstatus)\n")
	if statusOffset < 0 {
		t.Fatal("Buildroot restart action is incomplete")
	}
	restartAction := defaultBuildrootConfig[restartStart : restartStart+statusOffset]
	if !strings.Contains(restartAction, "\t\tstop &&\n\t\t\tstart") {
		t.Fatal("Buildroot restart must start immediately after a successful stop")
	}
	if strings.Contains(restartAction, "sleep") {
		t.Fatal("Buildroot restart must not add a post-stop delay")
	}
}

func TestRunitWaitUntilDown(t *testing.T) {
	directory := t.TempDir()
	svPath := filepath.Join(directory, "sv")
	if err := os.WriteFile(svPath, []byte("#!/bin/sh\nprintf 'down: %s: 0s, normally up\\n' \"$2\"\n"), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory)
	if err := (&runitRecord{name: "worker"}).waitUntilDown(); err != nil {
		t.Fatalf("waitUntilDown() error = %v", err)
	}
}

func TestLinuxWatcherTemplatesSuperviseApplications(t *testing.T) {
	tests := []struct {
		name   string
		source string
		wants  []string
	}{
		{name: "Buildroot", source: defaultBuildrootConfig, wants: []string{
			`PIDFILE=/var/run/$NAME.pid`,
			`IDENTITYFILE=${PIDFILE}.identity`,
			`INIT_SCRIPT=/etc/init.d/S90{{.Name}}`,
			`WATCHER_PIDFILE=${PIDFILE%.pid}.watchdog.pid`,
			`(umask 022; set -C; printf '%s\n' "$$" > "$WATCHER_PIDFILE")`,
			`watcher_identity=$(tr '\000' '\n' < "/proc/$watcher_pid/cmdline" | sed -n '2,3p')`,
			`while watcher_owns_pidfile; do`,
			`if is_running; then`,
			`watcher_sleep 1`,
			`watcher_sleep 30`,
			`"$INIT_SCRIPT" start watched`,
			`start() {`,
			`start_app || return $?`,
			`[ "$1" = "watched" ] && return 0`,
			`if ! start_watcher; then`,
			`Warning: $NAME watcher could not start`,
			`if ! disable_watcher; then`,
			"rm -f \"$PIDFILE\" \"$IDENTITYFILE\"\n\tif ! read_watcher_pid || ! is_watcher_process; then\n\t\trm -f \"$WATCHER_PIDFILE\"\n\tfi\n\techo \"$NAME is stopped\"\n\treturn 3",
			"unwatch)\n\t\tdisable_watcher",
		}},
		{name: "System V", source: defaultSystemVConfig, wants: []string{
			`pidfile="/var/run/$proc.pid"`,
			`identityfile="${pidfile}.identity"`,
			`init_script=/etc/init.d/{{.Name}}`,
			`watcher_pidfile=${pidfile%.pid}.watchdog.pid`,
			`(umask 022; set -C; printf '%s\n' "$$" > "$watcher_pidfile")`,
			`watcher_identity=$(tr '\000' '\n' < "/proc/$watcher_pid/cmdline" | sed -n '2,3p')`,
			`while watcher_owns_pidfile; do`,
			`if is_expected_process; then`,
			`watcher_sleep 1`,
			`watcher_sleep 30`,
			`"$init_script" start watched`,
			`start() {`,
			`start_app || return $?`,
			`[ "$1" = "watched" ] && return 0`,
			`if ! start_watcher; then`,
			`Warning: %s watcher could not start`,
			`if ! disable_watcher; then`,
			"if ! read_watcher_pid || ! is_watcher_process; then\n\t\trm -f \"$watcher_pidfile\"\n\tfi\n\tprintf '%s is stopped\\n' \"$proc\"\n\treturn 3",
			"unwatch)\n\t\tdisable_watcher",
		}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			for _, want := range test.wants {
				if !strings.Contains(test.source, want) {
					t.Errorf("template does not contain %q", want)
				}
			}
			watchedStart := strings.Index(test.source, `start watched`)
			disableWatcher := strings.Index(test.source, `if ! disable_watcher; then`)
			if watchedStart < 0 || disableWatcher < 0 {
				t.Fatal("template watcher control flow is incomplete")
			}
			applicationStop := strings.Index(test.source[disableWatcher:], `if ! is_running; then`)
			if test.name == "System V" {
				applicationStop = strings.Index(test.source[disableWatcher:], `if ! is_expected_process; then`)
			}
			if applicationStop < 0 {
				t.Fatal("template watcher control flow is incomplete")
			}
			for _, unwanted := range []string{"/var/run/daemon-util", "prepare_watcher_directory", "WATCH_INTERVAL", "watch_interval", "RESTART_DELAY", "restart_delay", "/etc/default/", "/etc/sysconfig/", "start_from_watch"} {
				if strings.Contains(test.source, unwanted) {
					t.Errorf("template still contains obsolete watcher directory logic %q", unwanted)
				}
			}
			if strings.Contains(test.source, "is running (watcher pid") {
				t.Error("template reports watcher-only state as running")
			}
		})
	}
}

func TestLinuxWatcherIdentityPrecedesSignal(t *testing.T) {
	tests := []struct {
		name          string
		source        string
		identityCheck string
		removePIDFile string
		termSignal    string
	}{
		{
			name:          "Buildroot",
			source:        defaultBuildrootConfig,
			identityCheck: `if ! read_watcher_pid || ! is_watcher_process; then`,
			removePIDFile: `rm -f "$WATCHER_PIDFILE" || return 1`,
			termSignal:    `kill -TERM "$watcher_pid"`,
		},
		{
			name:          "System V",
			source:        defaultSystemVConfig,
			identityCheck: `if ! read_watcher_pid || ! is_watcher_process; then`,
			removePIDFile: `rm -f "$watcher_pidfile" || return 1`,
			termSignal:    `kill -TERM "$watcher_pid"`,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			identityIndex := strings.Index(test.source, test.identityCheck)
			if identityIndex < 0 {
				t.Fatal("template does not validate watcher identity")
			}
			removeIndex := strings.Index(test.source[identityIndex:], test.removePIDFile)
			signalIndex := strings.Index(test.source[identityIndex:], test.termSignal)
			if removeIndex < 0 || signalIndex < 0 || removeIndex >= signalIndex {
				t.Fatal("watcher identity must be validated and disabled before it is signaled")
			}
		})
	}
}

func TestSystemVValidatesMainProcessBeforeSignals(t *testing.T) {
	for _, command := range []string{
		`[ "$pid" -gt 1 ]`,
		`identityfile="${pidfile}.identity"`,
		`process_starttime() {`,
		`shift 19`,
		`read_identity() {`,
		`record_identity() {`,
		`is_expected_executable() {`,
		`[ "$exec" -ef "/proc/$pid/exe" ]`,
		`if record_identity; then`,
		`if is_expected_executable && is_expected_process; then`,
		`[ "$current_starttime" = "$identity_starttime" ]`,
		`if ! is_expected_process; then`,
		`"$exec" {{.Args}}`,
		`if ! printf '%s\n' "$pid" > "$pidfile"; then`,
		`signal_process() {`,
		`is_expected_process || return 1`,
		`kill "-$process_signal" "$pid"`,
		`signal_process TERM`,
		`signal_process KILL`,
		`while is_expected_process && [ "$elapsed" -lt "$stop_timeout" ]`,
	} {
		if !strings.Contains(defaultSystemVConfig, command) {
			t.Fatalf("System V config does not contain %q", command)
		}
	}
	if strings.Contains(defaultSystemVConfig, `while kill -0 "$pid"`) {
		t.Fatal("System V stop loop still trusts raw PID liveness")
	}
	if strings.Contains(defaultSystemVConfig, `kill -TERM -- "-$pid"`) || strings.Contains(defaultSystemVConfig, `kill -KILL -- "-$pid"`) {
		t.Fatal("System V startup rollback still uses non-portable negative process-group signaling")
	}
	for _, processGroupImplementation := range []string{
		`setsid "$exec"`,
		`process_group_members() {`,
		`is_process_group_running() {`,
		`signal_process_group() {`,
	} {
		if strings.Contains(defaultSystemVConfig, processGroupImplementation) {
			t.Fatalf("System V config still contains custom process-group logic %q", processGroupImplementation)
		}
	}
	if strings.Contains(defaultSystemVConfig, `/proc/$pid/cmdline`) {
		t.Fatal("System V config still contains script-specific process matching")
	}
	identityStart := strings.Index(defaultSystemVConfig, "is_expected_process() {")
	if identityStart < 0 {
		t.Fatal("System V process identity function is missing")
	}
	identityEnd := strings.Index(defaultSystemVConfig[identityStart:], "\n}\n")
	if identityEnd < 0 {
		t.Fatal("System V process identity function is incomplete")
	}
	if strings.Contains(defaultSystemVConfig[identityStart:identityStart+identityEnd], `/proc/$pid/exe`) {
		t.Fatal("System V ongoing process identity still depends on the executable inode")
	}
}

func TestSystemVStatusDoesNotRequireRedHatHelpers(t *testing.T) {
	for _, setting := range []string{
		`service_status() {`,
		`printf '%s (pid  %s) is running...\n' "$proc" "$pid"`,
	} {
		if !strings.Contains(defaultSystemVConfig, setting) {
			t.Fatalf("System V config does not contain %q", setting)
		}
	}
	for _, dependency := range []string{
		`/etc/rc.d/init.d/functions`,
		`status -p $pidfile $proc`,
		"\tsuccess\n",
		"\tfailure\n",
	} {
		if strings.Contains(defaultSystemVConfig, dependency) {
			t.Fatalf("System V config still depends on %q", dependency)
		}
	}
	for index := 0; index+1 < len(defaultSystemVConfig); index++ {
		if defaultSystemVConfig[index:index+2] == `$"` && (index == 0 || defaultSystemVConfig[index-1] != '$') {
			t.Fatal(`System V config still depends on localized $"..." strings`)
		}
	}
}

func TestSystemVDetected(t *testing.T) {
	tests := []struct {
		name      string
		initPath  string
		runlevels []string
		want      bool
	}{
		{
			name:      "init directory with start runlevel",
			initPath:  "directory",
			runlevels: []string{"2"},
			want:      true,
		},
		{
			name:     "init directory without runlevels",
			initPath: "directory",
		},
		{
			name:      "init directory with stop runlevels only",
			initPath:  "directory",
			runlevels: []string{"0", "1", "6"},
		},
		{
			name: "missing init directory",
		},
		{
			name:     "init path is a file",
			initPath: "file",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			switch test.initPath {
			case "directory":
				if err := os.MkdirAll(filepath.Join(root, "etc/init.d"), 0755); err != nil {
					t.Fatal(err)
				}
			case "file":
				if err := os.MkdirAll(filepath.Join(root, "etc"), 0755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(root, "etc/init.d"), nil, 0755); err != nil {
					t.Fatal(err)
				}
			}
			for _, runlevel := range test.runlevels {
				if err := os.MkdirAll(filepath.Join(root, "etc", "rc"+runlevel+".d"), 0755); err != nil {
					t.Fatal(err)
				}
			}

			if got := systemVDetected(root); got != test.want {
				t.Fatalf("systemVDetected() = %v, want %v", got, test.want)
			}
		})
	}
}

func TestRunitDetected(t *testing.T) {
	tests := []struct {
		name            string
		serviceRoot     bool
		activeDirectory string
		activeRuntime   bool
		svPath          string
		want            bool
	}{
		{name: "active service directory", serviceRoot: true, activeDirectory: "directory", activeRuntime: true, svPath: "usr/bin/sv", want: true},
		{name: "active service symlink", serviceRoot: true, activeDirectory: "symlink", svPath: "bin/sv", want: true},
		{name: "missing service definitions", activeDirectory: "directory", activeRuntime: true, svPath: "usr/bin/sv"},
		{name: "missing active directory", serviceRoot: true, svPath: "usr/bin/sv"},
		{name: "missing active runtime", serviceRoot: true, activeDirectory: "directory", svPath: "usr/bin/sv"},
		{name: "active path is a file", serviceRoot: true, activeDirectory: "file", activeRuntime: true, svPath: "usr/bin/sv"},
		{name: "missing sv command", serviceRoot: true, activeDirectory: "directory", activeRuntime: true},
		{name: "missing chpst command", serviceRoot: true, activeDirectory: "directory", activeRuntime: true, svPath: "usr/bin/sv"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			t.Setenv("PATH", root)
			if test.svPath != "" {
				svPath := filepath.Join(root, test.svPath)
				commandDirectory := filepath.Dir(svPath)
				if err := os.MkdirAll(commandDirectory, 0755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(svPath, nil, 0755); err != nil {
					t.Fatal(err)
				}
				if test.name != "missing chpst command" {
					if err := os.WriteFile(filepath.Join(commandDirectory, "chpst"), nil, 0755); err != nil {
						t.Fatal(err)
					}
				}
				t.Setenv("PATH", commandDirectory)
			}
			if test.serviceRoot {
				if err := os.MkdirAll(filepath.Join(root, "etc/sv"), 0755); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.MkdirAll(filepath.Join(root, "var"), 0755); err != nil {
				t.Fatal(err)
			}
			if test.activeRuntime {
				if err := os.MkdirAll(filepath.Join(root, "run/runit/runsvdir/current"), 0755); err != nil {
					t.Fatal(err)
				}
			}
			switch test.activeDirectory {
			case "directory":
				if err := os.Mkdir(filepath.Join(root, "var/service"), 0755); err != nil {
					t.Fatal(err)
				}
			case "symlink":
				target := filepath.Join(root, "run/runit/runsvdir/current")
				if err := os.MkdirAll(target, 0755); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(target, filepath.Join(root, "var/service")); err != nil {
					t.Fatal(err)
				}
			case "file":
				if err := os.WriteFile(filepath.Join(root, "var/service"), nil, 0644); err != nil {
					t.Fatal(err)
				}
			}

			if got := runitDetected(root); got != test.want {
				t.Fatalf("runitDetected() = %v, want %v", got, test.want)
			}
		})
	}
}

func TestRunitPrecedesFallbackBackends(t *testing.T) {
	positions := make(map[string]int)
	for index, backend := range linuxBackends {
		positions[backend.name] = index
	}
	for _, fallback := range []string{"buildroot-style init", "systemV"} {
		if positions["runit"] >= positions[fallback] {
			t.Fatalf("runit backend position %d must precede %s position %d", positions["runit"], fallback, positions[fallback])
		}
	}
}

func TestSystemVServiceLinksUseExistingRunlevelDirectories(t *testing.T) {
	root := t.TempDir()
	for _, runlevel := range []string{"2", "5", "6"} {
		if err := os.MkdirAll(filepath.Join(root, "etc", "rc"+runlevel+".d"), 0755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "etc", "rc3.d"), nil, 0644); err != nil {
		t.Fatal(err)
	}

	links, hasStartLink := existingSystemVServiceLinks(root, "worker")
	want := []string{
		filepath.Join(root, "etc", "rc2.d", "S87worker"),
		filepath.Join(root, "etc", "rc5.d", "S87worker"),
		filepath.Join(root, "etc", "rc6.d", "K17worker"),
	}
	if strings.Join(links, "\n") != strings.Join(want, "\n") {
		t.Fatalf("systemVServiceLinks() = %q, want %q", links, want)
	}
	if !hasStartLink {
		t.Fatal("systemVServiceLinks() did not report an existing start runlevel")
	}
}

func TestSystemVServiceLinksRequireStartRunlevel(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "etc", "rc0.d"), 0755); err != nil {
		t.Fatal(err)
	}

	links, hasStartLink := existingSystemVServiceLinks(root, "worker")
	want := []string{filepath.Join(root, "etc", "rc0.d", "K17worker")}
	if strings.Join(links, "\n") != strings.Join(want, "\n") {
		t.Fatalf("systemVServiceLinks() = %q, want %q", links, want)
	}
	if hasStartLink {
		t.Fatal("systemVServiceLinks() reported a missing start runlevel")
	}
}

func TestBuildrootStyleInitDetected(t *testing.T) {
	tests := []struct {
		name       string
		rcS        string
		helperMode os.FileMode
		want       bool
	}{
		{
			name:       "direct init scan with daemon helper",
			rcS:        "#!/bin/sh\nfor script in /etc/init.d/S??*; do\n\t$script start\ndone\n",
			helperMode: 0755,
			want:       true,
		},
		{
			name:       "sysv runlevel scan",
			rcS:        "#!/bin/sh\nfor script in /etc/rcS.d/S??*; do\n\t$script start\ndone\n",
			helperMode: 0755,
			want:       false,
		},
		{
			name:       "missing daemon helper",
			rcS:        "#!/bin/sh\nfor script in /etc/init.d/S??*; do\n\t$script start\ndone\n",
			helperMode: 0,
			want:       false,
		},
		{
			name:       "non-executable daemon helper",
			rcS:        "#!/bin/sh\nfor script in /etc/init.d/S??*; do\n\t$script start\ndone\n",
			helperMode: 0644,
			want:       false,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			t.Setenv("PATH", root)
			initDirectory := filepath.Join(root, "etc/init.d")
			if err := os.MkdirAll(initDirectory, 0755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(initDirectory, "rcS"), []byte(test.rcS), 0755); err != nil {
				t.Fatal(err)
			}

			if test.helperMode != 0 {
				helperDirectory := filepath.Join(root, "sbin")
				if err := os.MkdirAll(helperDirectory, 0755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(helperDirectory, "start-stop-daemon"), nil, test.helperMode); err != nil {
					t.Fatal(err)
				}
				t.Setenv("PATH", helperDirectory)
			}

			if got := buildrootStyleInitDetected(root); got != test.want {
				t.Fatalf("buildrootStyleInitDetected() = %v, want %v", got, test.want)
			}
		})
	}
}

func TestDisableInstalledWatcher(t *testing.T) {
	directory := t.TempDir()
	watchedScript := filepath.Join(directory, "watched")
	content := "#!/bin/sh\n[ \"$1\" = unwatch ]\n"
	if err := os.WriteFile(watchedScript, []byte(content), 0755); err != nil {
		t.Fatal(err)
	}
	if err := disableInstalledWatcher(watchedScript); err != nil {
		t.Fatalf("watcher-aware script did not receive unwatch: %v", err)
	}
}

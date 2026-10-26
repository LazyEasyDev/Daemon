package cloudhook_test

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestShellScriptsKeepLFWithWindowsCheckout(t *testing.T) {
	for _, tool := range []string{"git", "sh"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("checkout test requires %s: %v", tool, err)
		}
	}
	dir := t.TempDir()
	runGit := func(args ...string) {
		t.Helper()
		command := exec.Command("git", append([]string{
			"-C", dir, "-c", "core.autocrlf=true", "-c", "core.safecrlf=false",
		}, args...)...)
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, output)
		}
	}
	runGit("init", "--quiet")
	files := []string{".gitattributes", "cloud_hook/aws_start.sh", "cloud_hook/azure_start.sh", "build.sh", "cloud_hook/build.sh"}
	for _, name := range files {
		data, err := os.ReadFile(filepath.Join("..", name))
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	runGit("add", "--all")
	for _, name := range files {
		if err := os.Remove(filepath.Join(dir, name)); err != nil {
			t.Fatal(err)
		}
	}
	runGit("checkout-index", "--all")
	for _, name := range files[1:] {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(dir, name)
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if bytes.Contains(data, []byte("\r\n")) {
				t.Fatal("Git converted the shell script to CRLF")
			}
			if output, err := exec.Command("sh", "-n", path).CombinedOutput(); err != nil {
				t.Fatalf("shell syntax failed: %v\n%s", err, output)
			}
			if strings.HasSuffix(name, "_start.sh") {
				output, err := exec.Command("sh", path, "--help").CombinedOutput()
				if err != nil || !strings.Contains(string(output), "Usage:") {
					t.Fatalf("--help failed: %v\n%s", err, output)
				}
			}
		})
	}
}

func newWindowsStartFixture(t *testing.T, provider string) cloudStartFixture {
	t.Helper()
	fixture := newCloudStartFixture(t, provider)
	fixture.env = append(fixture.env,
		"TEST_OS=MINGW64_NT-10.0-20348",
		"TEST_TARGET_OS=windows",
		"TEST_EXTENSION=.exe",
		"PROCESSOR_ARCHITECTURE=AMD64",
		"PROCESSOR_ARCHITEW6432=",
	)
	return fixture
}

func TestWindowsStartInstallsMatchingHook(t *testing.T) {
	for _, provider := range []string{"aws", "azure"} {
		t.Run(provider, func(t *testing.T) {
			for _, test := range []struct {
				name, arch string
				env        []string
			}{
				{name: "AMD64", arch: "amd64"},
				{name: "ARM64", arch: "arm64", env: []string{"PROCESSOR_ARCHITECTURE=ARM64"}},
				{name: "emulated shell", arch: "arm64", env: []string{"PROCESSOR_ARCHITEW6432=ARM64"}},
				{name: "uname fallback", arch: "arm64", env: []string{"PROCESSOR_ARCHITECTURE=", "TEST_ARCH_NAME=aarch64"}},
				{name: "MSYS", arch: "amd64", env: []string{"TEST_OS=MSYS_NT-10.0-20348"}},
				{name: "existing matching shortcut", arch: "amd64"},
			} {
				t.Run(test.name, func(t *testing.T) {
					fixture := newWindowsStartFixture(t, provider)
					fixture.env = append(fixture.env, test.env...)
					fixture.env = append(fixture.env, "TEST_ARCH="+test.arch)
					target := filepath.Join(fixture.dir, "build", "daemon-windows-"+test.arch+".exe")
					link := filepath.Join(fixture.binDir, "daemon.exe")
					if test.name == "existing matching shortcut" {
						if err := os.Symlink(target, link); err != nil {
							t.Fatal(err)
						}
					}
					output, err := fixture.run()
					if err != nil {
						t.Fatalf("setup failed: %v\n%s", err, output)
					}
					if got, err := os.Readlink(link); err != nil || got != target {
						t.Fatalf("shortcut = %q, error = %v; want %q", got, err, target)
					}
					commands := fixture.commands(t)
					hook := filepath.Join(fixture.dir, "cloud_hook", "build", provider+"_hook-windows-"+test.arch+".exe")
					for _, want := range []string{
						"windows preflight\n",
						"build daemon\nbuild hooks\n",
						"windows shortcut\n",
						"daemon <install> <" + provider + "Hook> <C:" + hook + ">",
						"daemon <start> <" + provider + "Hook>",
					} {
						if !strings.Contains(commands, want) {
							t.Errorf("missing %q in commands:\n%s", want, commands)
						}
					}
					if strings.Contains(commands, "systemd") || strings.Contains(commands, "sudo") {
						t.Fatalf("Windows setup used Linux management:\n%s", commands)
					}
					if strings.Count(commands, "daemon <install>") != 1 {
						t.Fatal("setup must install only the matching hook")
					}
					if !strings.Contains(output, ".exe.1.log") || strings.Contains(output, "journalctl") {
						t.Fatalf("incorrect Windows log instructions: %s", output)
					}
					before := fixture.commands(t)
					if output, err := fixture.run(); err == nil || !strings.Contains(output, "already installed") {
						t.Fatalf("repeat setup: output = %q, error = %v", output, err)
					}
					after := strings.TrimPrefix(fixture.commands(t), before)
					if strings.Contains(after, "build ") || strings.Contains(after, "daemon <") {
						t.Fatalf("repeat setup rebuilt or changed services:\n%s", after)
					}
				})
			}
		})
	}
}

func TestWindowsStartRejectsInvalidSetup(t *testing.T) {
	for _, provider := range []string{"aws", "azure"} {
		t.Run(provider, func(t *testing.T) {
			for _, name := range []string{"unsupported CPU", "32-bit shell", "not administrator", "SCM unavailable", "existing shortcut", "unrelated link", "existing hook", "shortcut failure", "shadowed command", "hook start failure"} {
				t.Run(name, func(t *testing.T) {
					fixture := newWindowsStartFixture(t, provider)
					switch name {
					case "unsupported CPU":
						fixture.env = append(fixture.env, "PROCESSOR_ARCHITECTURE=x86")
					case "32-bit shell":
						fixture.env = append(fixture.env, "TEST_ARCH_NAME=i686")
					case "not administrator":
						fixture.env = append(fixture.env, "TEST_WINDOWS_ADMIN=0")
					case "SCM unavailable":
						fixture.env = append(fixture.env, "TEST_WINDOWS_SCM_FAIL=1")
					case "existing shortcut":
						if err := os.WriteFile(filepath.Join(fixture.binDir, "daemon.exe"), []byte("unrelated"), 0755); err != nil {
							t.Fatal(err)
						}
					case "unrelated link":
						if err := os.Symlink(filepath.Join(fixture.dir, "fake-daemon"), filepath.Join(fixture.binDir, "daemon.exe")); err != nil {
							t.Fatal(err)
						}
					case "existing hook":
						if err := os.WriteFile(filepath.Join(fixture.unitDir, "lz_lz_"+provider+"Hook.service"), nil, 0644); err != nil {
							t.Fatal(err)
						}
					case "shortcut failure":
						fixture.env = append(fixture.env, "TEST_WINDOWS_LINK_FAIL=1")
					case "shadowed command":
						fixture.env = append(fixture.env, "TEST_WINDOWS_SHADOW=1")
					case "hook start failure":
						fixture.env = append(fixture.env, "TEST_START_FAIL=1")
					}
					output, err := fixture.run()
					if err == nil || strings.Contains(output, "Installed daemon shortcut:") {
						t.Fatalf("output = %q, error = %v", output, err)
					}
					commands := fixture.commands(t)
					if name != "hook start failure" && strings.Contains(commands, "daemon <install>") {
						t.Fatal("installed a service after validation failed")
					}
					if name != "shortcut failure" && name != "shadowed command" && name != "hook start failure" && strings.Contains(commands, "build daemon") {
						t.Fatal("built binaries before preflight failed")
					}
				})
			}
		})
	}
}

package cloudhook_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAzureStartInstallsShortcutAndHook(t *testing.T) {
	for _, arch := range []string{"amd64", "arm64"} {
		t.Run(arch, func(t *testing.T) {
			fixture := newCloudStartFixture(t, "azure")
			fixture.env = append(fixture.env, "TEST_BUILD_MODE=700")
			if arch == "arm64" {
				fixture.env = append(fixture.env, "TEST_ARCH_NAME=aarch64", "TEST_ARCH=arm64", "TEST_UID=1000")
			}
			output, err := fixture.run()
			if err != nil {
				t.Fatalf("setup failed: %v\n%s", err, output)
			}
			target := filepath.Join(fixture.dir, "build", "daemon-linux-"+arch)
			link, err := os.Readlink(filepath.Join(fixture.binDir, "daemon"))
			if err != nil || link != target {
				t.Fatalf("shortcut = %q, error = %v; want %q", link, err, target)
			}
			commands := fixture.commands(t)
			hook := filepath.Join(fixture.dir, "cloud_hook", "build", "azure_hook-linux-"+arch)
			for _, want := range []string{
				"build daemon\nbuild hooks\n",
				"daemon <install> <azureHook> <" + hook + ">",
				"daemon <start> <azureHook>",
			} {
				if !strings.Contains(commands, want) {
					t.Errorf("missing %q in commands:\n%s", want, commands)
				}
			}
			if strings.Count(commands, "daemon <install>") != 1 || strings.Contains(commands, "awsHook") {
				t.Fatal("setup must install only the Azure hook")
			}
			if !strings.Contains(output, "does not configure Azure notifications") {
				t.Fatal("missing Azure prerequisite warning")
			}
			for _, path := range []string{filepath.Dir(target), filepath.Dir(hook), target, hook} {
				info, err := os.Stat(path)
				if err != nil {
					t.Fatal(err)
				}
				if info.Mode().Perm() != 0755 {
					t.Errorf("%s mode = %v, want 755", path, info.Mode())
				}
			}
			before := fixture.commands(t)
			if output, err := fixture.run(); err == nil || !strings.Contains(output, "azureHook is already installed") {
				t.Fatalf("repeat setup: output = %q, error = %v", output, err)
			}
			after := strings.TrimPrefix(fixture.commands(t), before)
			if strings.Contains(after, "build ") || strings.Contains(after, "daemon <") {
				t.Fatalf("repeat setup rebuilt or changed services:\n%s", after)
			}
		})
	}
}

func TestAzureStartRejectsInvalidSetup(t *testing.T) {
	for _, name := range []string{"non-linux", "unsupported CPU", "no systemd", "existing shortcut", "shadowed command", "hook start failure"} {
		t.Run(name, func(t *testing.T) {
			fixture := newCloudStartFixture(t, "azure")
			switch name {
			case "non-linux":
				fixture.env = append(fixture.env, "TEST_OS=Darwin")
			case "unsupported CPU":
				fixture.env = append(fixture.env, "TEST_ARCH_NAME=mips")
			case "no systemd":
				fixture.env = append(fixture.env, "TEST_SYSTEMD_EXIT=1")
			case "existing shortcut":
				if err := os.WriteFile(filepath.Join(fixture.binDir, "daemon"), []byte("unrelated"), 0755); err != nil {
					t.Fatal(err)
				}
			case "shadowed command":
				if err := os.WriteFile(filepath.Join(fixture.dir, "fake-bin", "daemon"), []byte("#!/bin/sh\nexit 0\n"), 0755); err != nil {
					t.Fatal(err)
				}
			case "hook start failure":
				fixture.env = append(fixture.env, "TEST_START_FAIL=1")
			}
			output, err := fixture.run()
			if err == nil || strings.Contains(output, "Installed daemon shortcut:") {
				t.Fatalf("output = %q, error = %v", output, err)
			}
			if name == "no systemd" && !strings.Contains(output, "A running, accessible systemd service manager is required.") {
				t.Fatalf("missing systemd prerequisite error: %s", output)
			}
			commands := fixture.commands(t)
			if name != "hook start failure" && strings.Contains(commands, "daemon <install>") {
				t.Fatal("installed a service after setup validation failed")
			}
			if name != "shadowed command" && name != "hook start failure" && strings.Contains(commands, "build daemon") {
				t.Fatal("built binaries before preflight failed")
			}
		})
	}
}

func TestAzureStartHelpAndArguments(t *testing.T) {
	for _, argument := range []string{"--help", "--unknown", "myservice"} {
		t.Run(argument, func(t *testing.T) {
			fixture := newCloudStartFixture(t, "azure")
			output, err := fixture.run(argument)
			if (err == nil) != (argument == "--help") || !strings.Contains(output, "Usage: sh ./cloud_hook/azure_start.sh") {
				t.Fatalf("output = %q, error = %v", output, err)
			}
			if commands := fixture.commands(t); commands != "" {
				t.Fatalf("performed setup for %s:\n%s", argument, commands)
			}
		})
	}
}

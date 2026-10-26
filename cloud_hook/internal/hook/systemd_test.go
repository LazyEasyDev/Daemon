//go:build !windows

package hook

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
)

func TestUnitFromCgroup(t *testing.T) {
	for _, test := range []struct {
		name, data, want string
	}{
		{"v2", "0::/system.slice/lz_lz_awsHook.service\n", "lz_lz_awsHook.service"},
		{"v1", "2:cpu:/ignored.service\n1:name=systemd:/system.slice/lz_lz_custom.service\n", "lz_lz_custom.service"},
		{"subgroup", "0::/system.slice/lz_lz_azureHook.service/worker\n", "lz_lz_azureHook.service"},
		{"hybrid", "0::/system.slice/lz_lz_hook.service\n1:name=systemd:/system.slice/lz_lz_hook.service\n", "lz_lz_hook.service"},
		{"foreground", "0::/user.slice/session-1.scope\n", ""},
		{"unmanaged", "0::/system.slice/other.service\n", ""},
		{"conflict", "0::/system.slice/lz_lz_one.service\n1:name=systemd:/lz_lz_two.service\n", ""},
		{"invalid", "0::/system.slice/lz_lz_invalid-name.service\n", ""},
		{"empty", "", ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := unitFromCgroup(test.data)
			if test.want == "" {
				if err == nil {
					t.Fatal("expected an error")
				}
			} else if err != nil || got != test.want {
				t.Fatalf("unit = %q, error = %v; want %q", got, err, test.want)
			}
		})
	}
}

func TestStopServicesBatchesApplicationsAndExcludesSelf(t *testing.T) {
	var calls [][]string
	command := func(_ context.Context, name string, args ...string) ([]byte, error) {
		calls = append(calls, append([]string{name}, args...))
		switch args[0] {
		case "list-unit-files":
			return []byte("lz_lz_z.service enabled enabled\nlz_lz_hook.service enabled enabled\nlz_lz_a.service disabled enabled\nlz_lz_z.service enabled enabled\n"), nil
		case "stop":
			return nil, nil
		case "show":
			return []byte("Result=success\nActiveState=inactive\n"), nil
		default:
			t.Fatalf("unexpected command: %v", args)
			return nil, nil
		}
	}
	if err := StopServices(context.Background(), "lz_lz_hook.service", command); err != nil {
		t.Fatal(err)
	}
	want := [][]string{
		{"systemctl", "list-unit-files", "--type=service", "--no-legend", "--no-pager", "lz_lz_*.service"},
		{"systemctl", "stop", "--", "lz_lz_a.service", "lz_lz_z.service"},
		{"systemctl", "show", "--property=ActiveState", "--property=Result", "--", "lz_lz_a.service"},
		{"systemctl", "show", "--property=ActiveState", "--property=Result", "--", "lz_lz_z.service"},
	}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("calls = %v; want %v", calls, want)
	}
}

func TestStopServicesFailsClosed(t *testing.T) {
	for _, test := range []struct {
		name, listing, state, failCommand string
	}{
		{name: "discovery failure", failCommand: "list-unit-files"},
		{name: "watcher missing", listing: "lz_lz_app.service enabled"},
		{name: "unmanaged unit", listing: "lz_lz_hook.service enabled\nsshd.service enabled"},
		{name: "option injection", listing: "lz_lz_hook.service enabled\n--all enabled"},
		{name: "stop error", failCommand: "stop"},
		{name: "show error", failCommand: "show"},
		{name: "timeout result", state: "ActiveState=failed\nResult=timeout\n"},
		{name: "still running", state: "ActiveState=active\nResult=success\n"},
		{name: "missing properties", state: "garbage"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if test.listing == "" {
				test.listing = "lz_lz_hook.service enabled\nlz_lz_app.service enabled\n"
			}
			stopCalls := 0
			command := func(_ context.Context, _ string, args ...string) ([]byte, error) {
				if args[0] == "stop" {
					stopCalls++
				}
				if args[0] == test.failCommand {
					return nil, errors.New("command failed")
				}
				if args[0] == "list-unit-files" {
					return []byte(test.listing), nil
				}
				return []byte(test.state), nil
			}
			err := StopServices(context.Background(), "lz_lz_hook.service", command)
			if err == nil {
				t.Fatal("expected a stop failure")
			}
			if (test.name == "watcher missing" || test.name == "unmanaged unit" || test.name == "option injection") && stopCalls != 0 {
				t.Fatal("stopped services after unsafe discovery")
			}
		})
	}
}

func TestStopServicesWithoutApplications(t *testing.T) {
	calls := 0
	err := StopServices(context.Background(), "lz_lz_hook.service", func(context.Context, string, ...string) ([]byte, error) {
		calls++
		return []byte("lz_lz_hook.service enabled enabled\n"), nil
	})
	if err != nil || calls != 1 {
		t.Fatalf("error = %v, calls = %d", err, calls)
	}
}

func TestStopServicesRejectsInvalidSelf(t *testing.T) {
	err := StopServices(context.Background(), "", func(context.Context, string, ...string) ([]byte, error) {
		t.Fatal("command executed without identifying watcher")
		return nil, nil
	})
	if err == nil || !strings.Contains(err.Error(), "watcher unit") {
		t.Fatalf("error = %v", err)
	}
}

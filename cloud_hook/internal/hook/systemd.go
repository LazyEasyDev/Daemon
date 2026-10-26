//go:build !windows

package hook

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"slices"
	"strings"
)

var managedUnit = regexp.MustCompile(`^lz_lz_[A-Za-z][A-Za-z0-9]{0,240}\.service$`)

type Command func(context.Context, string, ...string) ([]byte, error)

func runCommand(ctx context.Context, name string, args ...string) ([]byte, error) {
	output, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("%s %v: %w: %s", name, args, err, strings.TrimSpace(string(output)))
	}
	return output, nil
}

func ownUnit() (string, error) {
	if _, err := os.Stat("/run/systemd/system"); err != nil {
		return "", fmt.Errorf("systemd is required: %w", err)
	}
	if _, err := exec.LookPath("systemctl"); err != nil {
		return "", err
	}
	data, err := os.ReadFile("/proc/self/cgroup")
	if err != nil {
		return "", err
	}
	return unitFromCgroup(string(data))
}

func unitFromCgroup(data string) (string, error) {
	var unit string
	for _, line := range strings.Split(data, "\n") {
		parts := strings.SplitN(line, ":", 3)
		if len(parts) != 3 || parts[1] != "" && parts[1] != "name=systemd" {
			continue
		}
		components := strings.Split(parts[2], "/")
		for i := len(components) - 1; i >= 0; i-- {
			if !strings.HasSuffix(components[i], ".service") {
				continue
			}
			if unit != "" && unit != components[i] {
				return "", fmt.Errorf("conflicting systemd service units in process cgroups")
			}
			unit = components[i]
			break
		}
	}
	if !managedUnit.MatchString(unit) {
		return "", fmt.Errorf("hook must be installed as a daemon-managed systemd service; found own unit %q", unit)
	}
	return unit, nil
}

func StopServices(ctx context.Context, self string, command Command) error {
	if !managedUnit.MatchString(self) {
		return fmt.Errorf("cannot safely exclude invalid watcher unit %q", self)
	}
	output, err := command(ctx, "systemctl", "list-unit-files", "--type=service", "--no-legend", "--no-pager", "lz_lz_*.service")
	if err != nil {
		return err
	}
	var units []string
	selfFound := false
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		unit := fields[0]
		if !managedUnit.MatchString(unit) {
			return fmt.Errorf("unexpected managed unit in systemctl output: %q", unit)
		}
		if unit == self {
			selfFound = true
		} else if !slices.Contains(units, unit) {
			units = append(units, unit)
		}
	}
	if !selfFound {
		return fmt.Errorf("watcher unit %q missing from managed services; refusing to stop applications", self)
	}
	if len(units) == 0 {
		return nil
	}
	slices.Sort(units)
	// Submit one stop transaction, allowing systemd to honor unit dependencies.
	if _, err := command(ctx, "systemctl", append([]string{"stop", "--"}, units...)...); err != nil {
		return err
	}
	for _, unit := range units {
		output, err := command(ctx, "systemctl", "show", "--property=ActiveState", "--property=Result", "--", unit)
		if err != nil {
			return err
		}
		properties := make(map[string]string)
		for _, line := range strings.Split(string(output), "\n") {
			if key, value, ok := strings.Cut(line, "="); ok {
				properties[key] = value
			}
		}
		if properties["ActiveState"] != "inactive" || properties["Result"] != "success" {
			return fmt.Errorf("%s did not stop cleanly: ActiveState=%q Result=%q", unit, properties["ActiveState"], properties["Result"])
		}
	}
	return nil
}

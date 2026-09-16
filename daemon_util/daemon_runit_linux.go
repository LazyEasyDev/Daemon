// Copyright (c) 2026 LazyEasyDev
// Licensed under the MIT License. See LICENSE in the project root.

//go:build linux

package daemon_util

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"text/template"
	"time"
)

const runitCommandWaitSeconds int64 = 7

type runitRecord struct {
	serviceConfig
	name           string
	description    string
	executablePath string
}

func runitDetected(root string) bool {
	for _, path := range []string{"etc/sv", "var/service", "run/runit/runsvdir/current"} {
		info, err := os.Stat(filepath.Join(root, path))
		if err != nil || !info.IsDir() {
			return false
		}
	}
	for _, command := range []string{"chpst", "sv"} {
		if _, err := exec.LookPath(command); err != nil {
			return false
		}
	}
	return true
}

func (linux *runitRecord) servicePath() string {
	return "/etc/sv/" + linux.name
}

func (linux *runitRecord) enabledPath() string {
	return "/var/service/" + linux.name
}

func (linux *runitRecord) downPath() string {
	return filepath.Join(linux.servicePath(), "down")
}

func (linux *runitRecord) stopTimeoutPath() string {
	return filepath.Join(linux.servicePath(), "daemon-util-stop-timeout")
}

func (linux *runitRecord) isInstalled() bool {
	if _, err := os.Lstat(linux.servicePath()); err == nil {
		return true
	}
	_, err := os.Lstat(linux.enabledPath())
	return err == nil
}

func (linux *runitRecord) statusCommand() *exec.Cmd {
	return exec.Command("sv", "status", linux.enabledPath())
}

func (linux *runitRecord) startCommand() *exec.Cmd {
	return exec.Command("sv", "-w", strconv.FormatInt(runitCommandWaitSeconds, 10), "start", linux.enabledPath())
}

func (linux *runitRecord) stopCommand() *exec.Cmd {
	timeout := readRunitStopTimeout(linux.stopTimeoutPath(), linux.stopTimeoutSeconds())
	return exec.Command("sv", "-w", strconv.FormatInt(timeout, 10), "force-stop", linux.enabledPath())
}

func (linux *runitRecord) shutdownCommand() *exec.Cmd {
	timeout := readRunitStopTimeout(linux.stopTimeoutPath(), linux.stopTimeoutSeconds())
	return exec.Command("sv", "-w", strconv.FormatInt(timeout, 10), "force-shutdown", linux.servicePath())
}

func readRunitStopTimeout(path string, fallback int64) int64 {
	content, err := os.ReadFile(path)
	if err != nil {
		return fallback
	}
	timeout, err := strconv.ParseInt(strings.TrimSpace(string(content)), 10, 64)
	if err != nil || timeout <= 0 {
		return fallback
	}
	return timeout
}

type runitServiceState uint8

const (
	runitServiceUnknown runitServiceState = iota
	runitServiceDown
	runitServiceRun
	runitServiceFinish
)

func (state runitServiceState) running() bool {
	return state == runitServiceRun
}

func (state runitServiceState) startable() bool {
	return state == runitServiceDown || state == runitServiceFinish
}

func (state runitServiceState) stoppable() bool {
	// A down service may still be awaiting respawn. Send the stop command to
	// cancel further restarts without changing boot enablement.
	return state == runitServiceDown || state == runitServiceRun || state == runitServiceFinish
}

func (linux *runitRecord) checkStatus() (string, runitServiceState, error) {
	output, err := linux.statusCommand().CombinedOutput()
	state, recognized := runitStatus(string(output), commandExitCode(err))
	if !recognized {
		return "", runitServiceUnknown, statusCommandError("runit", linux.name, output, err)
	}
	switch state {
	case runitServiceRun:
		return "Service is running...", state, nil
	case runitServiceFinish:
		return "Service is finishing...", state, nil
	default:
		return "Service is stopped", state, nil
	}
}

func (linux *runitRecord) checkRunning() (string, bool, error) {
	message, state, err := linux.checkStatus()
	return message, state.running(), err
}

func runitStatus(status string, exitCode int) (runitServiceState, bool) {
	if exitCode != 0 {
		return runitServiceUnknown, false
	}
	status = strings.TrimSpace(status)
	if strings.HasPrefix(status, "run: ") {
		return runitServiceRun, true
	}
	if strings.HasPrefix(status, "finish: ") {
		return runitServiceFinish, true
	}
	if strings.HasPrefix(status, "down: ") {
		return runitServiceDown, true
	}
	return runitServiceUnknown, false
}

func runitUnsupervised(status string, exitCode int) bool {
	if exitCode == 0 {
		return false
	}
	status = strings.ToLower(strings.TrimSpace(status))
	return (strings.HasPrefix(status, "fail: ") || strings.HasPrefix(status, "warning: ")) &&
		strings.Contains(status, "unable to open supervise/")
}

func (linux *runitRecord) waitUntilSupervisedDown() error {
	deadline := time.Now().Add(time.Duration(runitCommandWaitSeconds) * time.Second)
	var lastOutput []byte
	var lastErr error
	for {
		output, err := linux.statusCommand().CombinedOutput()
		state, recognized := runitStatus(string(output), commandExitCode(err))
		if recognized {
			if state != runitServiceDown {
				return fmt.Errorf("runit started %s while its down marker was present", linux.name)
			}
			return nil
		}
		lastOutput, lastErr = output, err
		if !time.Now().Before(deadline) {
			return statusCommandError("runit", linux.name, lastOutput, lastErr)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func (linux *runitRecord) waitUntilDown() error {
	deadline := time.Now().Add(time.Duration(runitCommandWaitSeconds) * time.Second)
	var lastOutput []byte
	var lastErr error
	for {
		output, err := linux.statusCommand().CombinedOutput()
		state, recognized := runitStatus(string(output), commandExitCode(err))
		if recognized && state == runitServiceDown {
			return nil
		}
		lastOutput, lastErr = output, err
		if !time.Now().Before(deadline) {
			return statusCommandError("runit", linux.name, lastOutput, lastErr)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func (linux *runitRecord) shutdownSupervisor() error {
	output, err := linux.shutdownCommand().CombinedOutput()
	if err == nil {
		return nil
	}
	statusOutput, statusErr := exec.Command("sv", "status", linux.servicePath()).CombinedOutput()
	if runitUnsupervised(string(statusOutput), commandExitCode(statusErr)) {
		return nil
	}
	return statusCommandError("runit shutdown", linux.name, output, err)
}

func (linux *runitRecord) removeFiles() error {
	if err := os.Remove(linux.enabledPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if _, err := os.Lstat(linux.servicePath()); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}
	if err := linux.shutdownSupervisor(); err != nil {
		return err
	}
	return os.RemoveAll(linux.servicePath())
}

func (linux *runitRecord) Install(args ...string) (string, error) {
	installAction := "Install " + linux.description + ":"

	if ok, err := checkPrivileges(); !ok {
		return installAction + failed, err
	}
	if linux.isInstalled() {
		return installAction + failed, ErrAlreadyInstalled
	}

	executablePath, err := resolveExecutablePath(linux.name, linux.executablePath)
	if err != nil {
		return installAction + failed, err
	}
	if err := os.Mkdir(linux.servicePath(), 0755); err != nil {
		return installAction + failed, err
	}

	rollback := func(cause error) (string, error) {
		return installAction + failed, errors.Join(cause, linux.removeFiles())
	}
	if err := writeTemplateFile(
		filepath.Join(linux.servicePath(), "run"),
		"runitConfig",
		defaultRunitConfig,
		template.FuncMap{"shellQuote": shellQuote},
		&struct {
			Path, Args, WorkingDirectory string
		}{executablePath, shellQuoteArgs(args), filepath.Dir(executablePath)},
		0755,
	); err != nil {
		return rollback(err)
	}
	controlDirectory := filepath.Join(linux.servicePath(), "control")
	if err := os.Mkdir(controlDirectory, 0755); err != nil {
		return rollback(err)
	}
	for _, control := range []struct {
		name   string
		signal string
	}{
		{name: "t", signal: "TERM"},
		{name: "k", signal: "KILL"},
	} {
		if err := writeTemplateFile(
			filepath.Join(controlDirectory, control.name),
			"runitControlConfig",
			defaultRunitControlConfig,
			template.FuncMap{"shellQuote": shellQuote},
			&struct {
				PIDFile, Signal string
			}{filepath.Join(linux.servicePath(), "supervise", "pid"), control.signal},
			0755,
		); err != nil {
			return rollback(err)
		}
	}
	stopTimeout := strconv.FormatInt(linux.stopTimeoutSeconds(), 10) + "\n"
	if err := os.WriteFile(linux.stopTimeoutPath(), []byte(stopTimeout), 0644); err != nil {
		return rollback(err)
	}
	if err := os.WriteFile(linux.downPath(), nil, 0644); err != nil {
		return rollback(err)
	}
	if err := os.Symlink(linux.servicePath(), linux.enabledPath()); err != nil {
		return rollback(err)
	}
	if err := linux.waitUntilSupervisedDown(); err != nil {
		return rollback(err)
	}
	if err := os.Remove(linux.downPath()); err != nil {
		return rollback(err)
	}

	return installAction + success, nil
}

func (linux *runitRecord) Remove() (string, error) {
	removeAction := "Removing " + linux.description + ":"

	if ok, err := checkPrivileges(); !ok {
		return removeAction + failed, err
	}
	if !linux.isInstalled() {
		return removeAction + failed, ErrNotInstalled
	}
	if err := linux.removeFiles(); err != nil {
		return removeAction + failed, err
	}

	return removeAction + success, nil
}

func (linux *runitRecord) Start() (string, error) {
	startAction := "Starting " + linux.description + ":"

	if ok, err := checkPrivileges(); !ok {
		return startAction + failed, err
	}
	if !linux.isInstalled() {
		return startAction + failed, ErrNotInstalled
	}
	if _, state, err := linux.checkStatus(); err != nil {
		return startAction + failed, err
	} else if !state.startable() {
		return startAction + failed, ErrAlreadyRunning
	}
	if err := os.Remove(linux.downPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return startAction + failed, err
	}
	if err := linux.startCommand().Run(); err != nil {
		return startAction + failed, err
	}

	return startAction + success, nil
}

func (linux *runitRecord) Stop() (string, error) {
	stopAction := "Stopping " + linux.description + ":"

	if ok, err := checkPrivileges(); !ok {
		return stopAction + failed, err
	}
	if !linux.isInstalled() {
		return stopAction + failed, ErrNotInstalled
	}
	if _, state, err := linux.checkStatus(); err != nil {
		return stopAction + failed, err
	} else if !state.stoppable() {
		return stopAction + failed, ErrAlreadyStopped
	}
	if err := linux.stopCommand().Run(); err != nil {
		if waitErr := linux.waitUntilDown(); waitErr != nil {
			return stopAction + failed, errors.Join(err, waitErr)
		}
	}

	return stopAction + success, nil
}

func (linux *runitRecord) Status() (string, error) {
	if ok, err := checkPrivileges(); !ok {
		return "", err
	}
	if !linux.isInstalled() {
		return statNotInstalled, ErrNotInstalled
	}

	status, _, err := linux.checkRunning()
	return status, err
}

const defaultRunitConfig = `#!/bin/sh

cd {{shellQuote .WorkingDirectory}} || exit 111
exec chpst -P {{shellQuote .Path}}{{if .Args}} {{.Args}}{{end}}
`

const defaultRunitControlConfig = `#!/bin/sh

pidfile={{shellQuote .PIDFile}}
pid=$(cat "$pidfile") || exit 1
case "$pid" in
	''|*[!0-9]*) exit 1 ;;
esac
[ "$pid" -gt 1 ] || exit 1

process_stat=$(cat "/proc/$pid/stat") || exit 1
process_after_name=${process_stat##*) }
[ "$process_after_name" != "$process_stat" ] || exit 1
set -- $process_after_name
[ "$#" -ge 3 ] || exit 1
[ "$3" = "$pid" ] || exit 1

kill -{{.Signal}} "-$pid"
`

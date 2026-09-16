// Copyright (c) 2026 LazyEasyDev
// Licensed under the MIT License. See LICENSE in the project root.

//go:build linux

package daemon_util

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"text/template"
)

// systemDRecord - standard record (struct) for linux systemD version of daemon package
type systemDRecord struct {
	serviceConfig
	name           string
	description    string
	executablePath string
}

// Standard service path for systemD daemons
func (linux *systemDRecord) servicePath() string {
	return "/etc/systemd/system/" + linux.name + ".service"
}

// Is a service installed
func (linux *systemDRecord) isInstalled() bool {

	if _, err := os.Stat(linux.servicePath()); err == nil {
		return true
	}

	return false
}

// Check service is running
func (linux *systemDRecord) checkRunning() (string, bool, error) {
	output, err := exec.Command("systemctl", "is-active", linux.name+".service").CombinedOutput()
	running, recognized := systemDStatus(string(output))
	if !recognized || err != nil && commandExitCode(err) != 3 {
		return "", false, statusCommandError("systemd", linux.name, output, err)
	}
	if running {
		return "Service is running...", true, nil
	}
	return "Service is stopped", false, nil
}

func systemDStatus(status string) (running, recognized bool) {
	switch strings.TrimSpace(status) {
	case "active", "activating", "reloading", "refreshing", "deactivating":
		return true, true
	case "inactive", "failed":
		return false, true
	default:
		return false, false
	}
}

// Journald's stream setup needs room for a newline after the unit name.
// A 255-byte unit filename is valid on disk but fails this native protocol.
const maxSystemDUnitNameLength = 254

func validateSystemDInstallName(name string) error {
	if len(name)+len(".service") > maxSystemDUnitNameLength {
		return fmt.Errorf("%w: systemd service names must not exceed %d characters", ErrInvalidName,
			maxSystemDUnitNameLength-len(".service")-len(managedServicePrefix))
	}
	return nil
}

// Install the service
func (linux *systemDRecord) Install(args ...string) (string, error) {
	installAction := "Install " + linux.description + ":"

	if ok, err := checkPrivileges(); !ok {
		return installAction + failed, err
	}

	srvPath := linux.servicePath()

	if linux.isInstalled() {
		return installAction + failed, ErrAlreadyInstalled
	}
	if err := validateSystemDInstallName(linux.name); err != nil {
		return installAction + failed, err
	}

	execPatch, err := resolveExecutablePath(linux.name, linux.executablePath)
	if err != nil {
		return installAction + failed, err
	}
	if err := validateSystemDExecutablePath(execPatch); err != nil {
		return installAction + failed, err
	}

	funcs := template.FuncMap{
		"systemdQuote":       systemdQuote,
		"systemdDescription": systemdDescription,
		"systemdPathValue":   systemdPathValue,
	}
	if err := writeTemplateFile(
		srvPath,
		"systemDConfig",
		defaultSystemDConfig,
		funcs,
		&struct {
			Name, Description, Path, Args, WorkingDirectory string
			StopTimeoutSeconds                              int64
		}{
			linux.name,
			linux.description,
			execPatch,
			systemdQuoteArgs(args),
			filepath.Dir(execPatch),
			linux.stopTimeoutSeconds(),
		},
		0644,
	); err != nil {
		return installAction + failed, err
	}

	if err := exec.Command("systemctl", "daemon-reload").Run(); err != nil {
		_ = os.Remove(srvPath)
		return installAction + failed, err
	}

	if err := exec.Command("systemctl", "enable", linux.name+".service").Run(); err != nil {
		_ = exec.Command("systemctl", "disable", linux.name+".service").Run()
		_ = os.Remove(srvPath)
		_ = exec.Command("systemctl", "daemon-reload").Run()
		return installAction + failed, err
	}

	return installAction + success, nil
}

// Remove the service
func (linux *systemDRecord) Remove() (string, error) {
	removeAction := "Removing " + linux.description + ":"

	if ok, err := checkPrivileges(); !ok {
		return removeAction + failed, err
	}

	if !linux.isInstalled() {
		return removeAction + failed, ErrNotInstalled
	}

	if err := exec.Command("systemctl", "disable", linux.name+".service").Run(); err != nil {
		return removeAction + failed, err
	}

	if err := os.Remove(linux.servicePath()); err != nil {
		return removeAction + failed, err
	}
	if err := exec.Command("systemctl", "daemon-reload").Run(); err != nil {
		return removeAction + failed, err
	}

	return removeAction + success, nil
}

// Start the service
func (linux *systemDRecord) Start() (string, error) {
	startAction := "Starting " + linux.description + ":"

	if ok, err := checkPrivileges(); !ok {
		return startAction + failed, err
	}

	if !linux.isInstalled() {
		return startAction + failed, ErrNotInstalled
	}

	if _, running, err := linux.checkRunning(); err != nil {
		return startAction + failed, err
	} else if running {
		return startAction + failed, ErrAlreadyRunning
	}

	if err := exec.Command("systemctl", "start", linux.name+".service").Run(); err != nil {
		return startAction + failed, err
	}

	return startAction + success, nil
}

// Stop the service
func (linux *systemDRecord) Stop() (string, error) {
	stopAction := "Stopping " + linux.description + ":"

	if ok, err := checkPrivileges(); !ok {
		return stopAction + failed, err
	}

	if !linux.isInstalled() {
		return stopAction + failed, ErrNotInstalled
	}
	if _, running, err := linux.checkRunning(); err != nil {
		return stopAction + failed, err
	} else if !running {
		return stopAction + failed, ErrAlreadyStopped
	}

	if err := exec.Command("systemctl", "stop", linux.name+".service").Run(); err != nil {
		return stopAction + failed, err
	}

	return stopAction + success, nil
}

// Status - Get service status
func (linux *systemDRecord) Status() (string, error) {

	if ok, err := checkPrivileges(); !ok {
		return "", err
	}

	if !linux.isInstalled() {
		return statNotInstalled, ErrNotInstalled
	}

	statusAction, _, err := linux.checkRunning()
	return statusAction, err
}

const defaultSystemDConfig = `[Unit]
Description={{systemdDescription .Description}}

[Service]
Type=exec
ExecStart={{systemdQuote .Path}} {{.Args}}
WorkingDirectory={{systemdPathValue .WorkingDirectory}}
Restart=on-failure
RestartPreventExitStatus=203
RestartSec=20s
TimeoutStopSec={{.StopTimeoutSeconds}}s
KillMode=control-group

[Install]
WantedBy=multi-user.target
`

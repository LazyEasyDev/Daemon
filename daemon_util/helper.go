// Copyright (c) 2026 LazyEasyDev
// Licensed under the MIT License. See LICENSE in the project root.

package daemon_util

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"text/template"
)

const (
	success = " [OK]"
	failed  = " [FAILED]"
)

var (
	// ErrUnsupportedSystem appears if try to use service on system which is not supported by this release
	ErrUnsupportedSystem = errors.New("Unsupported system")

	// ErrRootPrivileges appears if run installation or deleting the service without root privileges
	ErrRootPrivileges = errors.New("You must have root user privileges. Possibly using 'sudo' command should help")

	// ErrAlreadyInstalled appears if service already installed on the system
	ErrAlreadyInstalled = errors.New("Service has already been installed")

	// ErrNotInstalled appears if try to delete service which was not been installed
	ErrNotInstalled = errors.New("Service is not installed")

	// ErrAlreadyRunning appears if try to start already running service
	ErrAlreadyRunning = errors.New("Service is already running")

	// ErrAlreadyStopped appears if try to stop already stopped service
	ErrAlreadyStopped = errors.New("Service has already been stopped")
)

// ExecPath tries to get executable path
func ExecPath() (string, error) {
	return os.Executable()
}

func readExecutableMagic(path string) ([4]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return [4]byte{}, err
	}
	defer file.Close()

	var magic [4]byte
	_, err = io.ReadFull(file, magic[:])
	return magic, err
}

func resolveExecutablePath(name, configuredPath string) (string, error) {
	path := configuredPath
	if path == "" {
		executable, err := ExecPath()
		if err != nil {
			return "", err
		}
		path = filepath.Join(filepath.Dir(executable), name)
	}
	return ResolveExecutablePath(path)
}

// ResolveExecutablePath returns the absolute, symlink-resolved path to a
// native executable for the current operating system.
func ResolveExecutablePath(path string) (string, error) {
	absolutePath, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	resolvedPath, err := filepath.EvalSymlinks(absolutePath)
	if err != nil {
		return "", err
	}
	if err := validateExecutable(resolvedPath); err != nil {
		return "", err
	}
	return resolvedPath, nil
}

// ValidateExecutablePath verifies that path identifies a native executable for
// the current operating system.
func ValidateExecutablePath(path string) error {
	return validateExecutable(path)
}

type serviceDirectory struct {
	path       string
	filePrefix string
	suffix     string
	isRunning  func(string) (bool, error)
}

func listServiceStatuses(directories ...serviceDirectory) ([]ServiceStatus, error) {
	statuses := make(map[string]string)
	for _, directory := range directories {
		entries, err := os.ReadDir(directory.path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		for _, entry := range entries {
			if entry.IsDir() {
				continue
			}
			filename := entry.Name()
			if !strings.HasPrefix(filename, directory.filePrefix) || !strings.HasSuffix(filename, directory.suffix) {
				continue
			}
			registrationName := strings.TrimPrefix(filename, directory.filePrefix)
			registrationName = strings.TrimSuffix(registrationName, directory.suffix)
			logicalName, ok := logicalServiceName(registrationName)
			if !ok {
				continue
			}

			status := ServiceStopped
			if directory.isRunning != nil {
				running, err := directory.isRunning(registrationName)
				if err != nil {
					return nil, fmt.Errorf("query status for %s: %w", logicalName, err)
				}
				if running {
					status = ServiceRunning
				}
			}
			if current, exists := statuses[logicalName]; !exists || current != ServiceRunning {
				statuses[logicalName] = status
			}
		}
	}
	return sortedServiceStatuses(statuses), nil
}

func sortedServiceStatuses(statuses map[string]string) []ServiceStatus {
	names := make([]string, 0, len(statuses))
	for name := range statuses {
		names = append(names, name)
	}
	sort.Strings(names)

	result := make([]ServiceStatus, 0, len(statuses))
	for _, name := range names {
		result = append(result, ServiceStatus{Name: name, Status: statuses[name]})
	}
	return result
}

func quoteArgs(args []string, quote func(string) string) string {
	quoted := make([]string, len(args))
	for i, arg := range args {
		quoted[i] = quote(arg)
	}
	return strings.Join(quoted, " ")
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

func shellQuoteArgs(args []string) string {
	return quoteArgs(args, shellQuote)
}

func upstartQuote(value string) string {
	return strconv.Quote(value)
}

func systemdQuote(value string) string {
	quoted := strconv.Quote(value)
	quoted = strings.ReplaceAll(quoted, "$", "$$")
	return strings.ReplaceAll(quoted, "%", "%%")
}

func systemdQuoteArgs(args []string) string {
	return quoteArgs(args, systemdQuote)
}

func systemdDescription(value string) string {
	escaped := strings.ReplaceAll(value, "%", "%%")
	if strings.HasSuffix(escaped, `\`) {
		return escaped + " "
	}
	return escaped
}

func systemdPathValue(value string) string {
	return strings.ReplaceAll(value, "%", "%%")
}

func validateSystemDExecutablePath(path string) error {
	for _, character := range path {
		if character < ' ' || character == 0x7f || strings.ContainsRune(`$'"\`, character) {
			return fmt.Errorf("%w: character %q is not supported by systemd executable paths", ErrInvalidExecutablePath, character)
		}
	}
	if strings.HasSuffix(filepath.Dir(path), " ") {
		return fmt.Errorf("%w: systemd working directory must not end with a space", ErrInvalidExecutablePath)
	}
	return nil
}

func statusCommandError(manager, name string, output []byte, err error) error {
	detail := strings.TrimSpace(string(output))
	if err != nil && detail != "" {
		return fmt.Errorf("query %s status for %s: %w: %s", manager, name, err, detail)
	}
	if err != nil {
		return fmt.Errorf("query %s status for %s: %w", manager, name, err)
	}
	if detail != "" {
		return fmt.Errorf("query %s status for %s: unexpected response %q", manager, name, detail)
	}
	return fmt.Errorf("query %s status for %s: empty response", manager, name)
}

func commandExitCode(err error) int {
	if err == nil {
		return 0
	}
	var exitError *exec.ExitError
	if errors.As(err, &exitError) {
		return exitError.ExitCode()
	}
	return -1
}

func writeTemplateFile(path, name, source string, funcs template.FuncMap, data any, mode fs.FileMode) error {
	templ, err := template.New(name).Funcs(funcs).Parse(source)
	if err != nil {
		return err
	}

	var content bytes.Buffer
	if err := templ.Execute(&content, data); err != nil {
		return err
	}

	temporary, err := os.CreateTemp(filepath.Dir(path), ".daemon-util-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	defer temporary.Close()

	if err := temporary.Chmod(mode); err != nil {
		return err
	}
	if _, err := temporary.Write(content.Bytes()); err != nil {
		return err
	}
	if err := temporary.Sync(); err != nil {
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}

	return os.Rename(temporaryPath, path)
}

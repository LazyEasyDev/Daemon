package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"time"

	"github.com/LazyEasyDev/Daemon/daemon_util"
)

type serviceMetadata struct {
	ApplicationPath    string `json:"application_path"`
	Arguments          string `json:"arguments"`
	StopTimeoutSeconds int64  `json:"stop_timeout_seconds,omitempty"`
}

func defaultServiceMetadataDirectory() (string, error) {
	switch runtime.GOOS {
	case "darwin":
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		return filepath.Join(home, "Library", "Application Support", "daemon-util", "services"), nil
	case "linux":
		return "/var/lib/daemon-util/services", nil
	case "freebsd":
		return "/var/db/daemon-util/services", nil
	case "windows":
		programData := os.Getenv("ProgramData")
		if programData == "" {
			return "", errors.New("ProgramData is not set")
		}
		return filepath.Join(programData, "daemon-util", "services"), nil
	default:
		return "", fmt.Errorf("unsupported metadata platform %q", runtime.GOOS)
	}
}

func serviceMetadataPath(directory, serviceName string) (string, error) {
	managedName, err := daemon_util.ManagedServiceName(serviceName)
	if err != nil {
		return "", err
	}
	return filepath.Join(directory, managedName+".json"), nil
}

func writeServiceMetadata(serviceName, applicationPath, arguments string, stopTimeout time.Duration) error {
	directory, err := defaultServiceMetadataDirectory()
	if err != nil {
		return err
	}
	return writeServiceMetadataTo(directory, serviceName, applicationPath, arguments, stopTimeout)
}

func writeServiceMetadataTo(directory, serviceName, applicationPath, arguments string, stopTimeout time.Duration) error {
	path, err := serviceMetadataPath(directory, serviceName)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(directory, 0755); err != nil {
		return err
	}

	content, err := json.Marshal(serviceMetadata{
		ApplicationPath:    applicationPath,
		Arguments:          arguments,
		StopTimeoutSeconds: int64(stopTimeout / time.Second),
	})
	if err != nil {
		return err
	}
	content = append(content, '\n')

	temporary, err := os.CreateTemp(directory, ".daemon-util-metadata-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	closed := false
	defer func() {
		if !closed {
			_ = temporary.Close()
		}
		_ = os.Remove(temporaryPath)
	}()

	if _, err := temporary.Write(content); err != nil {
		return err
	}
	if err := temporary.Chmod(0644); err != nil {
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	closed = true
	return os.Rename(temporaryPath, path)
}

func readServiceMetadata(serviceName string) string {
	return readServiceMetadataRecord(serviceName).ApplicationPath
}

func readServiceMetadataRecord(serviceName string) serviceMetadata {
	directory, err := defaultServiceMetadataDirectory()
	if err != nil {
		return serviceMetadata{}
	}
	return readServiceMetadataRecordFrom(directory, serviceName)
}

func readServiceMetadataFrom(directory, serviceName string) string {
	return readServiceMetadataRecordFrom(directory, serviceName).ApplicationPath
}

func readServiceStopTimeout(serviceName string) (time.Duration, bool) {
	directory, err := defaultServiceMetadataDirectory()
	if err != nil {
		return 0, false
	}
	return readServiceStopTimeoutFrom(directory, serviceName)
}

func readServiceStopTimeoutFrom(directory, serviceName string) (time.Duration, bool) {
	seconds := readServiceMetadataRecordFrom(directory, serviceName).StopTimeoutSeconds
	if seconds <= 0 {
		return 0, false
	}
	return time.Duration(seconds) * time.Second, true
}

func readServiceMetadataRecordFrom(directory, serviceName string) serviceMetadata {
	path, err := serviceMetadataPath(directory, serviceName)
	if err != nil {
		return serviceMetadata{}
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return serviceMetadata{}
	}

	var metadata serviceMetadata
	if err := json.Unmarshal(content, &metadata); err != nil {
		return serviceMetadata{}
	}
	return metadata
}

func removeServiceMetadata(serviceName string) error {
	directory, err := defaultServiceMetadataDirectory()
	if err != nil {
		return err
	}
	return removeServiceMetadataFrom(directory, serviceName)
}

func removeServiceMetadataFrom(directory, serviceName string) error {
	path, err := serviceMetadataPath(directory, serviceName)
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

package hook

import (
	"context"
	"errors"
	"fmt"
	"os"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

type nativeSCMService struct {
	service *mgr.Service
}

func (service nativeSCMService) query() (scmStatus, error) {
	status, err := service.service.Query()
	if err != nil {
		return scmStatus{}, err
	}
	return scmStatus{
		stopped:      status.State == svc.Stopped,
		stopping:     status.State == svc.StopPending,
		pid:          status.ProcessId,
		exitCode:     status.Win32ExitCode,
		specificCode: status.ServiceSpecificExitCode,
	}, nil
}

func (service nativeSCMService) stop() error {
	_, err := service.service.Control(svc.Stop)
	if errors.Is(err, windows.ERROR_SERVICE_NOT_ACTIVE) {
		return nil
	}
	return err
}

func withSCMServices(action func([]scmEntry) error) (err error) {
	handle, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_CONNECT|windows.SC_MANAGER_ENUMERATE_SERVICE)
	if err != nil {
		return fmt.Errorf("connect to Windows Service Control Manager (LocalSystem or administrative service permissions required): %w", err)
	}
	manager := &mgr.Mgr{Handle: handle}
	defer func() {
		err = errors.Join(err, manager.Disconnect())
	}()

	names, err := manager.ListServices()
	if err != nil {
		return fmt.Errorf("list Windows services: %w", err)
	}
	var entries []scmEntry
	for _, name := range names {
		if !managedWindowsService.MatchString(name) {
			continue
		}
		pointer, conversionErr := windows.UTF16PtrFromString(name)
		if conversionErr != nil {
			return conversionErr
		}
		serviceHandle, openErr := windows.OpenService(manager.Handle, pointer, windows.SERVICE_QUERY_STATUS|windows.SERVICE_STOP)
		if openErr != nil {
			return fmt.Errorf("open managed Windows service %s: %w", name, openErr)
		}
		service := &mgr.Service{Name: name, Handle: serviceHandle}
		defer func() {
			if closeErr := service.Close(); closeErr != nil {
				err = errors.Join(err, fmt.Errorf("close Windows service %s: %w", service.Name, closeErr))
			}
		}()
		entries = append(entries, scmEntry{name: name, service: nativeSCMService{service: service}})
	}
	return action(entries)
}

func prepareServices() (string, func(context.Context) error, error) {
	parent := os.Getppid()
	if parent <= 0 {
		return "", nil, fmt.Errorf("cannot identify the daemon wrapper's parent process")
	}
	var self string
	deadline := time.Now().Add(30 * time.Second)
	for {
		err := withSCMServices(func(entries []scmEntry) error {
			var err error
			self, err = ownSCMService(entries, uint32(parent))
			return err
		})
		if err == nil {
			break
		}
		// SCM may not publish the wrapper's PID until it finishes starting.
		if !errors.Is(err, errSCMOwnerNotFound) || !time.Now().Before(deadline) {
			return "", nil, err
		}
		time.Sleep(100 * time.Millisecond)
	}
	return self, func(ctx context.Context) error {
		return withSCMServices(func(entries []scmEntry) error {
			current, err := ownSCMService(entries, uint32(parent))
			if err != nil {
				return err
			}
			if current != self {
				return fmt.Errorf("watcher's Windows service identity changed")
			}
			return stopSCMServices(ctx, self, entries, time.Second)
		})
	}, nil
}

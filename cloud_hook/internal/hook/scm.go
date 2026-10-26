package hook

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
)

var managedWindowsService = regexp.MustCompile(`(?i)^lz_lz_[a-z][a-z0-9]{0,240}$`)
var errSCMOwnerNotFound = errors.New("hook must run under the current daemon's Windows service wrapper")

type scmStatus struct {
	stopped, stopping           bool
	pid, exitCode, specificCode uint32
}

type scmService interface {
	query() (scmStatus, error)
	stop() error
}

type scmEntry struct {
	name    string
	service scmService
}

func ownSCMService(entries []scmEntry, parentPID uint32) (string, error) {
	if parentPID == 0 {
		return "", fmt.Errorf("cannot identify the daemon wrapper's process")
	}
	var self string
	for _, entry := range entries {
		status, err := entry.service.query()
		if err != nil {
			return "", fmt.Errorf("query %s: %w", entry.name, err)
		}
		// The daemon registers its wrapper with SCM and launches the hook as a child.
		if !status.stopped && status.pid == parentPID {
			if self != "" {
				return "", fmt.Errorf("multiple services share the hook parent's process ID")
			}
			self = entry.name
		}
	}
	if self == "" {
		return "", errSCMOwnerNotFound
	}
	if !managedWindowsService.MatchString(self) {
		return "", fmt.Errorf("invalid Windows watcher service %q", self)
	}
	return self, nil
}

func stopSCMServices(ctx context.Context, self string, entries []scmEntry, interval time.Duration) error {
	if !managedWindowsService.MatchString(self) || interval <= 0 {
		return fmt.Errorf("invalid Windows watcher service or polling interval")
	}
	selfFound := false
	statuses := make([]scmStatus, len(entries))
	for i, entry := range entries {
		if !managedWindowsService.MatchString(entry.name) {
			return fmt.Errorf("unexpected managed Windows service %q", entry.name)
		}
		if strings.EqualFold(entry.name, self) {
			selfFound = true
		}
		status, err := entry.service.query()
		if err != nil {
			return fmt.Errorf("query %s: %w", entry.name, err)
		}
		statuses[i] = status
	}
	if !selfFound {
		return fmt.Errorf("watcher service %q missing; refusing to stop applications", self)
	}

	var stopErrors []error
	for i, entry := range entries {
		if err := ctx.Err(); err != nil {
			return err
		}
		if strings.EqualFold(entry.name, self) || statuses[i].stopped || statuses[i].stopping {
			continue
		}
		// Request all stops before waiting for any service's cleanup to finish.
		if err := entry.service.stop(); err != nil {
			stopErrors = append(stopErrors, fmt.Errorf("stop %s: %w", entry.name, err))
		}
	}
	if len(stopErrors) != 0 {
		// Dependent services may need to stop before their prerequisites accept a stop.
		return errors.Join(stopErrors...)
	}

	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		pending := false
		for _, entry := range entries {
			if strings.EqualFold(entry.name, self) {
				continue
			}
			status, err := entry.service.query()
			if err != nil {
				return fmt.Errorf("query %s: %w", entry.name, err)
			}
			if status.stopped {
				if status.exitCode != 0 || status.specificCode != 0 {
					return fmt.Errorf("%s stopped with Windows exit code %d, service exit code %d", entry.name, status.exitCode, status.specificCode)
				}
			} else if status.stopping {
				pending = true
			} else {
				return fmt.Errorf("%s is no longer stopping; refusing to report successful cleanup", entry.name)
			}
		}
		if !pending {
			return nil
		}
		timer := time.NewTimer(interval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}

package hook

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

type fakeSCMService struct {
	status   scmStatus
	queryErr error
	stopErr  error
	stops    int
	onQuery  func() (scmStatus, error)
	onStop   func()
}

func (service *fakeSCMService) query() (scmStatus, error) {
	if service.onQuery != nil {
		return service.onQuery()
	}
	return service.status, service.queryErr
}

func (service *fakeSCMService) stop() error {
	service.stops++
	if service.onStop != nil {
		service.onStop()
	}
	if service.stopErr == nil {
		service.status = scmStatus{stopped: true}
	}
	return service.stopErr
}

func TestOwnSCMServiceUsesWrapperParentNotExecutableName(t *testing.T) {
	entries := []scmEntry{
		{"lz_lz_app", &fakeSCMService{status: scmStatus{pid: 10}}},
		{"lz_lz_customHook", &fakeSCMService{status: scmStatus{pid: 20}}},
		{"lz_lz_stopped", &fakeSCMService{status: scmStatus{stopped: true}}},
	}
	self, err := ownSCMService(entries, 20)
	if err != nil || self != "lz_lz_customHook" {
		t.Fatalf("self = %q, error = %v", self, err)
	}
}

func TestOwnSCMServiceFailsClosed(t *testing.T) {
	for _, test := range []struct {
		name    string
		parent  uint32
		entries []scmEntry
	}{
		{"no parent", 0, nil},
		{"foreground", 20, []scmEntry{{"lz_lz_app", &fakeSCMService{status: scmStatus{pid: 10}}}}},
		{"startup PID unavailable", 20, []scmEntry{{"lz_lz_hook", &fakeSCMService{}}}},
		{"query error", 20, []scmEntry{{"lz_lz_hook", &fakeSCMService{queryErr: errors.New("access denied")}}}},
		{"stopped parent", 20, []scmEntry{{"lz_lz_hook", &fakeSCMService{status: scmStatus{pid: 20, stopped: true}}}}},
		{"unmanaged parent", 20, []scmEntry{{"other", &fakeSCMService{status: scmStatus{pid: 20}}}}},
		{"ambiguous parent", 20, []scmEntry{
			{"lz_lz_hook", &fakeSCMService{status: scmStatus{pid: 20}}},
			{"lz_lz_other", &fakeSCMService{status: scmStatus{pid: 20}}},
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			self, err := ownSCMService(test.entries, test.parent)
			if err == nil || self != "" {
				t.Fatalf("self = %q, error = %v", self, err)
			}
			if test.name == "startup PID unavailable" && !errors.Is(err, errSCMOwnerNotFound) {
				t.Fatalf("startup error is not retryable: %v", err)
			}
		})
	}
}

func TestStopSCMServicesRequestsAllStopsBeforeWaiting(t *testing.T) {
	self := &fakeSCMService{status: scmStatus{pid: 20}}
	a, b := &fakeSCMService{}, &fakeSCMService{}
	entries := []scmEntry{{"lz_lz_hook", self}, {"lz_lz_a", a}, {"lz_lz_b", b}}
	var operations []string
	for _, entry := range entries[1:] {
		service := entry.service.(*fakeSCMService)
		service.onStop = func() {
			operations = append(operations, "stop "+entry.name)
		}
		service.onQuery = func() (scmStatus, error) {
			if service.stops == 0 {
				return scmStatus{}, nil
			}
			operations = append(operations, "wait "+entry.name)
			return scmStatus{stopped: true}, nil
		}
	}
	if err := stopSCMServices(context.Background(), "LZ_LZ_HOOK", entries, time.Millisecond); err != nil {
		t.Fatal(err)
	}
	want := []string{"stop lz_lz_a", "stop lz_lz_b", "wait lz_lz_a", "wait lz_lz_b"}
	if !reflect.DeepEqual(operations, want) || self.stops != 0 {
		t.Fatalf("operations = %v, self stops = %d", operations, self.stops)
	}
}

func TestStopSCMServicesSkipsStoppedAndPending(t *testing.T) {
	self := &fakeSCMService{}
	stopped := &fakeSCMService{status: scmStatus{stopped: true}}
	pending := &fakeSCMService{}
	queries := 0
	pending.onQuery = func() (scmStatus, error) {
		queries++
		return scmStatus{stopped: queries >= 3, stopping: queries < 3}, nil
	}
	entries := []scmEntry{{"lz_lz_hook", self}, {"lz_lz_stopped", stopped}, {"lz_lz_pending", pending}}
	if err := stopSCMServices(context.Background(), "lz_lz_hook", entries, time.Millisecond); err != nil {
		t.Fatal(err)
	}
	if self.stops != 0 || stopped.stops != 0 || pending.stops != 0 || queries != 3 {
		t.Fatalf("stop counts = %d, %d, %d; queries = %d", self.stops, stopped.stops, pending.stops, queries)
	}
}

func TestStopSCMServicesDoesNotAbortOtherStopRequests(t *testing.T) {
	self := &fakeSCMService{}
	dependentStopped := false
	prerequisite := &fakeSCMService{}
	prerequisite.onStop = func() {
		if dependentStopped {
			prerequisite.stopErr = nil
		} else {
			prerequisite.stopErr = errors.New("dependent services running")
		}
	}
	dependent := &fakeSCMService{onStop: func() { dependentStopped = true }}
	entries := []scmEntry{{"lz_lz_hook", self}, {"lz_lz_database", prerequisite}, {"lz_lz_worker", dependent}}
	err := stopSCMServices(context.Background(), "lz_lz_hook", entries, time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), "dependent services running") || dependent.stops != 1 {
		t.Fatalf("error = %v; dependent stops = %d", err, dependent.stops)
	}
	if err := stopSCMServices(context.Background(), "lz_lz_hook", entries, time.Millisecond); err != nil {
		t.Fatal(err)
	}
	if prerequisite.stops != 2 || dependent.stops != 1 {
		t.Fatalf("stop counts = %d, %d", prerequisite.stops, dependent.stops)
	}
}

func TestStopSCMServicesFailures(t *testing.T) {
	for _, test := range []struct {
		name   string
		status scmStatus
	}{
		{"Windows failure", scmStatus{stopped: true, exitCode: 1}},
		{"service failure", scmStatus{stopped: true, specificCode: 1}},
		{"running after stop", scmStatus{}},
	} {
		t.Run(test.name, func(t *testing.T) {
			app := &fakeSCMService{onQuery: func() (scmStatus, error) { return test.status, nil }}
			err := stopSCMServices(context.Background(), "lz_lz_hook", []scmEntry{
				{"lz_lz_hook", &fakeSCMService{}}, {"lz_lz_app", app},
			}, time.Millisecond)
			if err == nil {
				t.Fatal("reported unsuccessful stopping as success")
			}
		})
	}
}

func TestStopSCMServicesPreflight(t *testing.T) {
	for _, test := range []struct {
		name     string
		self     string
		interval time.Duration
		entries  []scmEntry
	}{
		{"invalid self", "", time.Second, nil},
		{"invalid interval", "lz_lz_hook", 0, nil},
		{"missing self", "lz_lz_hook", time.Second, []scmEntry{{"lz_lz_app", &fakeSCMService{}}}},
		{"unmanaged service", "lz_lz_hook", time.Second, []scmEntry{
			{"lz_lz_hook", &fakeSCMService{}}, {"WinDefend", &fakeSCMService{}},
		}},
		{"query failure", "lz_lz_hook", time.Second, []scmEntry{
			{"lz_lz_hook", &fakeSCMService{}}, {"lz_lz_app", &fakeSCMService{queryErr: errors.New("query failed")}},
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			if err := stopSCMServices(context.Background(), test.self, test.entries, test.interval); err == nil {
				t.Fatal("accepted invalid service discovery")
			}
			for _, entry := range test.entries {
				if entry.service.(*fakeSCMService).stops != 0 {
					t.Fatal("stopped services before preflight succeeded")
				}
			}
		})
	}
}

func TestStopSCMServicesCancellation(t *testing.T) {
	t.Run("before stop requests", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		app := &fakeSCMService{}
		err := stopSCMServices(ctx, "lz_lz_hook", []scmEntry{
			{"lz_lz_hook", &fakeSCMService{}}, {"lz_lz_app", app},
		}, time.Millisecond)
		if !errors.Is(err, context.Canceled) || app.stops != 0 {
			t.Fatalf("error = %v; stops = %d", err, app.stops)
		}
	})
	t.Run("during wait", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		queries := 0
		app := &fakeSCMService{onQuery: func() (scmStatus, error) {
			queries++
			if queries > 1 {
				cancel()
			}
			return scmStatus{stopping: true}, nil
		}}
		err := stopSCMServices(ctx, "lz_lz_hook", []scmEntry{
			{"lz_lz_hook", &fakeSCMService{}}, {"lz_lz_app", app},
		}, time.Millisecond)
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("error = %v", err)
		}
	})
}

func TestStopSCMServicesReportsWaitQueryFailure(t *testing.T) {
	app := &fakeSCMService{}
	app.onQuery = func() (scmStatus, error) {
		if app.stops > 0 {
			return scmStatus{}, errors.New("query failed during wait")
		}
		return scmStatus{}, nil
	}
	err := stopSCMServices(context.Background(), "lz_lz_hook", []scmEntry{
		{"lz_lz_hook", &fakeSCMService{}}, {"lz_lz_app", app},
	}, time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), "query failed during wait") {
		t.Fatalf("error = %v", err)
	}
}

func TestStopSCMServicesWithoutApplications(t *testing.T) {
	self := &fakeSCMService{}
	err := stopSCMServices(context.Background(), "lz_lz_hook", []scmEntry{{"lz_lz_hook", self}}, time.Millisecond)
	if err != nil || self.stops != 0 {
		t.Fatalf("error = %v; self stops = %d", err, self.stops)
	}
}

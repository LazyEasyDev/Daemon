package hook

import (
	"bytes"
	"context"
	"errors"
	"log"
	"strings"
	"testing"
	"time"
)

func TestRunStopsOnceAndStaysAlive(t *testing.T) {
	for _, failStop := range []bool{false, true} {
		name := "success"
		if failStop {
			name = "stop failure"
		}
		t.Run(name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			var logs bytes.Buffer
			polls, stops := 0, 0
			ready := make(chan struct{})
			done := make(chan error, 1)
			go func() {
				done <- Run(ctx, time.Millisecond, func(context.Context) (string, error) {
					polls++
					switch polls {
					case 1:
						return "", errors.New("temporary metadata failure")
					case 2:
						return "", nil
					default:
						return "termination pending", nil
					}
				}, func(context.Context) error {
					stops++
					if stops == 1 {
						close(ready)
					}
					if failStop {
						return errors.New("temporary stop failure")
					}
					return nil
				}, log.New(&logs, "", 0))
			}()
			select {
			case <-ready:
			case <-time.After(5 * time.Second):
				t.Fatal("stop was not requested")
			}
			select {
			case err := <-done:
				t.Fatalf("watcher exited before OS shutdown: %v", err)
			case <-time.After(10 * time.Millisecond):
			}
			cancel()
			if err := <-done; err != nil {
				t.Fatal(err)
			}
			if polls != 3 || stops != 1 {
				t.Fatalf("polls = %d, stops = %d; want 3, 1", polls, stops)
			}
			messages := []string{"temporary metadata failure", "termination notice"}
			if failStop {
				messages = append(messages, "temporary stop failure", "application stop failed; not retrying")
				if strings.Contains(logs.String(), "managed applications stopped") {
					t.Fatal("reported successful cleanup after stop failure")
				}
			} else {
				messages = append(messages, "managed applications stopped")
			}
			for _, message := range messages {
				if !strings.Contains(logs.String(), message) {
					t.Errorf("missing log message %q", message)
				}
			}
		})
	}
}

func TestRunCancellationDuringStop(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var logs bytes.Buffer
	stops := 0
	err := Run(ctx, time.Second, func(context.Context) (string, error) {
		return "termination", nil
	}, func(context.Context) error {
		stops++
		cancel()
		return context.Canceled
	}, log.New(&logs, "", 0))
	if err != nil || stops != 1 {
		t.Fatalf("error = %v, stops = %d; want nil, 1", err, stops)
	}
	if strings.Contains(logs.String(), "managed applications stopped") {
		t.Fatal("reported successful cleanup after cancellation")
	}
}

func TestRunCancellationDoesNotStopApps(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err := Run(ctx, time.Second, func(context.Context) (string, error) {
		t.Fatal("polled after cancellation")
		return "", nil
	}, func(context.Context) error {
		t.Fatal("stopped apps after cancellation")
		return nil
	}, log.Default())
	if err != nil {
		t.Fatal(err)
	}
}

func TestRunCancellationDuringPollDoesNotStopApps(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	err := Run(ctx, time.Second, func(context.Context) (string, error) {
		cancel()
		return "termination", nil
	}, func(context.Context) error {
		t.Fatal("stopped apps after cancellation")
		return nil
	}, log.Default())
	if err != nil {
		t.Fatal(err)
	}
}

func TestRunRejectsInvalidInterval(t *testing.T) {
	if err := Run(context.Background(), 0, nil, nil, log.Default()); err == nil {
		t.Fatal("accepted zero interval")
	}
}

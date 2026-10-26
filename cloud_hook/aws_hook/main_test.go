package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/LazyEasyDev/Daemon/cloud_hook/internal/hook"
)

func TestAWSLifecyclePolling(t *testing.T) {
	state := "InService"
	tokens, gets := 0, 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/token":
			tokens++
			if r.Method != http.MethodPut || r.Header.Get("X-aws-ec2-metadata-token-ttl-seconds") != "21600" {
				t.Error("invalid IMDSv2 token request")
			}
			_, _ = fmt.Fprint(w, "secret-token")
		case "/meta-data/autoscaling/target-lifecycle-state":
			gets++
			if r.Header.Get("X-aws-ec2-metadata-token") != "secret-token" {
				t.Error("missing IMDSv2 token")
			}
			_, _ = fmt.Fprint(w, state)
		default:
			t.Errorf("unexpected endpoint %s", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	metadata := &awsMetadata{client: hook.NewHTTPClient(), baseURL: server.URL}
	for _, value := range []string{"InService", "Standby", "Detached", "Warmed:Running", "Warmed:Stopped", "Warmed:Hibernated", "Warmed:Terminated", "Terminated"} {
		state = value
		notice, err := metadata.poll(context.Background())
		if err != nil || (notice != "") != (state == "Terminated") {
			t.Fatalf("state = %s, notice = %q, error = %v", state, notice, err)
		}
	}
	if tokens != 1 || gets != 8 {
		t.Fatalf("tokens = %d, polls = %d", tokens, gets)
	}
	metadata.expiresAt = time.Now().Add(-time.Second)
	if _, err := metadata.poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	if tokens != 2 {
		t.Fatal("did not renew expired token")
	}
}

func TestAWSRefreshesRejectedToken(t *testing.T) {
	gets, tokens := 0, 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPut {
			tokens++
			_, _ = fmt.Fprintf(w, "token-%d", tokens)
			return
		}
		gets++
		if gets == 1 {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_, _ = fmt.Fprint(w, "Terminated")
	}))
	defer server.Close()
	metadata := &awsMetadata{client: hook.NewHTTPClient(), baseURL: server.URL}
	notice, err := metadata.poll(context.Background())
	if err != nil || notice == "" || gets != 2 || tokens != 2 {
		t.Fatalf("notice = %q, error = %v, gets = %d, tokens = %d", notice, err, gets, tokens)
	}
}

func TestAWSMetadataFailuresNeverTriggerCleanup(t *testing.T) {
	for _, test := range []struct {
		name, token, state string
		tokenCode, getCode int
	}{
		{"empty token", "", "Terminated", 200, 200},
		{"token unavailable", "secret", "Terminated", 403, 200},
		{"metadata absent", "secret", "", 200, 404},
		{"unauthorized", "secret", "", 200, 401},
		{"unexpected state", "secret", "Stopping", 200, 200},
		{"empty state", "secret", "", 200, 200},
		{"metadata server failure", "secret", "Terminated", 200, 500},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodPut {
					w.WriteHeader(test.tokenCode)
					_, _ = fmt.Fprint(w, test.token)
				} else {
					w.WriteHeader(test.getCode)
					_, _ = fmt.Fprint(w, test.state)
				}
			}))
			defer server.Close()
			metadata := &awsMetadata{client: hook.NewHTTPClient(), baseURL: server.URL}
			notice, err := metadata.poll(context.Background())
			if notice != "" || err == nil {
				t.Fatalf("notice = %q, error = %v", notice, err)
			}
			if strings.Contains(err.Error(), "secret") {
				t.Fatal("error exposed token")
			}
		})
	}
}

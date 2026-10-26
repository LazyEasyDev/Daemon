package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/LazyEasyDev/Daemon/cloud_hook/internal/hook"
)

func TestAzureFiltersEventsToThisInstance(t *testing.T) {
	for _, test := range []struct {
		name, kind, status, resource string
		want                         bool
	}{
		{"local name", "Terminate", "Scheduled", "pool_0", true},
		{"case insensitive", "Terminate", "Scheduled", "POOL_0", true},
		{"resource ID", "Terminate", "Scheduled", "/subscriptions/s/resourceGroups/r/providers/Microsoft.Compute/virtualMachineScaleSets/pool/virtualMachines/0", true},
		{"started", "Terminate", "Started", "pool_0", true},
		{"other VM", "Terminate", "Scheduled", "pool_1", false},
		{"other scale set", "Terminate", "Scheduled", "/subscriptions/s/resourceGroups/r/providers/Microsoft.Compute/virtualMachineScaleSets/other/virtualMachines/0", false},
		{"maintenance", "Reboot", "Scheduled", "pool_0", false},
		{"freeze", "Freeze", "Scheduled", "pool_0", false},
		{"spot not scale in", "Preempt", "Scheduled", "pool_0", false},
		{"empty resource", "Terminate", "Scheduled", "", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			identityCalls := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Metadata") != "true" || r.Method != http.MethodGet {
					t.Error("invalid Azure metadata request")
				}
				switch r.URL.Path {
				case "/instance/compute":
					identityCalls++
					if r.URL.Query().Get("api-version") != "2021-02-01" {
						t.Error("incorrect instance metadata version")
					}
					_, _ = fmt.Fprint(w, `{"name":"pool_0","resourceId":"/subscriptions/s/resourceGroups/r/providers/Microsoft.Compute/virtualMachineScaleSets/pool/virtualMachines/0"}`)
				case "/scheduledevents":
					if r.URL.Query().Get("api-version") != "2020-07-01" {
						t.Error("incorrect Scheduled Events version")
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"Events": []scheduledEvent{{
						EventID: "event-1", EventType: test.kind, EventStatus: test.status,
						ResourceType: "VirtualMachine", Resources: []string{test.resource},
						NotBefore: "Mon, 26 Oct 2026 08:00:00 GMT",
					}}})
				default:
					t.Errorf("unexpected endpoint %s", r.URL.Path)
					w.WriteHeader(404)
				}
			}))
			defer server.Close()
			metadata := &azureMetadata{client: hook.NewHTTPClient(), baseURL: server.URL}
			for range 2 {
				notice, err := metadata.poll(context.Background())
				if err != nil || (notice != "") != test.want {
					t.Fatalf("notice = %q, error = %v; want notice %v", notice, err, test.want)
				}
			}
			if identityCalls != 1 {
				t.Fatalf("identity calls = %d, want 1", identityCalls)
			}
		})
	}
}

func TestAzureMetadataValidation(t *testing.T) {
	for _, test := range []struct {
		name, identity, events string
		code                   int
		fail                   bool
	}{
		{"no events", `{"name":"vm"}`, `{"Events":[]}`, 200, false},
		{"identity invalid", `not-json`, `{"Events":[]}`, 200, true},
		{"identity absent", `{}`, `{"Events":[]}`, 200, true},
		{"whitespace identity", `{"name":" "}`, `{"Events":[]}`, 200, true},
		{"events invalid", `{"name":"vm"}`, `not-json`, 200, true},
		{"events absent", `{"name":"vm"}`, `{}`, 200, true},
		{"events null", `{"name":"vm"}`, `{"Events":null}`, 200, true},
		{"metadata error", `{"name":"vm"}`, `{}`, 503, true},
		{"missing event ID", `{"name":"vm"}`, `{"Events":[{"EventType":"Terminate","Resources":["vm"],"ResourceType":"VirtualMachine","EventStatus":"Scheduled"}]}`, 200, true},
		{"invalid resource type", `{"name":"vm"}`, `{"Events":[{"EventId":"1","EventType":"Terminate","Resources":["vm"],"ResourceType":"Other","EventStatus":"Scheduled"}]}`, 200, true},
		{"invalid status", `{"name":"vm"}`, `{"Events":[{"EventId":"1","EventType":"Terminate","Resources":["vm"],"ResourceType":"VirtualMachine","EventStatus":"Other"}]}`, 200, true},
		{"resource ID only", `{"resourceId":"/vm/0"}`, `{"Events":[{"EventId":"1","EventType":"Terminate","Resources":["/vm/0"],"ResourceType":"VirtualMachine","EventStatus":"Scheduled"}]}`, 200, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(test.code)
				if r.URL.Path == "/instance/compute" {
					_, _ = fmt.Fprint(w, test.identity)
				} else {
					_, _ = fmt.Fprint(w, test.events)
				}
			}))
			defer server.Close()
			metadata := &azureMetadata{client: hook.NewHTTPClient(), baseURL: server.URL}
			notice, err := metadata.poll(context.Background())
			if (err != nil) != test.fail || test.fail && notice != "" {
				t.Fatalf("notice = %q, error = %v; want failure %v", notice, err, test.fail)
			}
		})
	}
}

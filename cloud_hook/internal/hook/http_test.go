package hook

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestMetadataClientBypassesProxiesAndRejectsRedirects(t *testing.T) {
	client := NewHTTPClient()
	transport := client.Transport.(*http.Transport)
	if transport.Proxy != nil || client.Timeout != 5*time.Second {
		t.Fatal("metadata client must bypass proxies and use a bounded timeout")
	}
	targetCalls := 0
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		targetCalls++
	}))
	defer target.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL, http.StatusFound)
	}))
	defer server.Close()
	_, _, err := ReadMetadata(context.Background(), client, http.MethodGet, server.URL, nil)
	if err == nil || targetCalls != 0 {
		t.Fatalf("redirect error = %v, target calls = %d", err, targetCalls)
	}
}

func TestReadMetadataValidation(t *testing.T) {
	for _, test := range []struct {
		name string
		code int
		body string
		fail bool
	}{
		{"success", 200, "metadata", false},
		{"http error", 503, "do not log response contents", true},
		{"oversized", 200, strings.Repeat("x", maxMetadataSize+1), true},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Metadata") != "true" {
					t.Error("missing metadata header")
				}
				w.WriteHeader(test.code)
				_, _ = w.Write([]byte(test.body))
			}))
			defer server.Close()
			body, status, err := ReadMetadata(context.Background(), NewHTTPClient(), http.MethodGet, server.URL, map[string]string{"Metadata": "true"})
			if status != test.code || (err != nil) != test.fail {
				t.Fatalf("status = %d, error = %v", status, err)
			}
			if !test.fail && string(body) != test.body {
				t.Fatalf("body = %q", body)
			}
			if test.fail && err != nil && strings.Contains(err.Error(), test.body) {
				t.Fatal("error exposed metadata response contents")
			}
		})
	}
}

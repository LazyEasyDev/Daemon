package daemon_util

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWriteTemplateFileWithMaximumServiceName(t *testing.T) {
	registrationName, err := ManagedServiceName(strings.Repeat("a", 241))
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	path := filepath.Join(directory, registrationName+".service")

	for _, want := range []string{"initial configuration\n", "replacement configuration\n"} {
		if err := writeTemplateFile(path, "service", "{{.}}", nil, want, 0644); err != nil {
			t.Fatalf("write configuration for maximum-length service name: %v", err)
		}
		content, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if string(content) != want {
			t.Fatalf("configuration = %q, want %q", content, want)
		}
	}

	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != filepath.Base(path) {
		t.Fatalf("directory entries = %v, want only the service configuration", entries)
	}
}

func TestWriteTemplateFileCleansTemporaryAfterRenameFailure(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "existing-directory")
	if err := os.Mkdir(path, 0755); err != nil {
		t.Fatal(err)
	}
	if err := writeTemplateFile(path, "service", "configuration", nil, nil, 0644); err == nil {
		t.Fatal("writing a configuration over a directory unexpectedly succeeded")
	}

	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != filepath.Base(path) || !entries[0].IsDir() {
		t.Fatalf("directory entries = %v, want only the original directory", entries)
	}
}

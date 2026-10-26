package hook

import (
	"bytes"
	"errors"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func readLogPair(t *testing.T, path string, limit int64) [2]string {
	t.Helper()
	var contents [2]string
	for i, suffix := range []string{".1.log", ".2.log"} {
		data, err := os.ReadFile(path + suffix)
		if err != nil {
			t.Fatal(err)
		}
		if int64(len(data)) > limit {
			t.Fatalf("%s exceeds limit: %d bytes", suffix, len(data))
		}
		contents[i] = string(data)
	}
	return contents
}

func setLogPairTimes(t *testing.T, path string, newer int) {
	t.Helper()
	base := time.Date(2026, time.January, 1, 0, 0, 0, 0, time.UTC)
	for i, suffix := range []string{".1.log", ".2.log"} {
		modified := base
		if i == newer {
			modified = base.Add(time.Hour)
		}
		if err := os.Chtimes(path+suffix, modified, modified); err != nil {
			t.Fatal(err)
		}
	}
}

func TestRotatingLogFilesBoundaries(t *testing.T) {
	for _, test := range []struct {
		name      string
		existing  [2]string
		entry     string
		want      [2]string
		newer     int
		wantError bool
	}{
		{name: "new files", entry: "new\n", want: [2]string{"new\n", ""}},
		{name: "append", existing: [2]string{"old\n", ""}, entry: "ok\n", want: [2]string{"old\nok\n", ""}},
		{name: "exact limit", existing: [2]string{"old\n", ""}, entry: "new\n", want: [2]string{"old\nnew\n", ""}},
		{name: "cross limit", existing: [2]string{"old\n", "stale\n"}, entry: "long\n", want: [2]string{"old\n", "long\n"}},
		{name: "already full", existing: [2]string{"12345678", ""}, entry: "new\n", want: [2]string{"12345678", "new\n"}},
		{name: "already oversized", existing: [2]string{"1234567890", ""}, entry: "new\n", want: [2]string{"new\n", ""}},
		{name: "oversized entry", existing: [2]string{"old\n", "older\n"}, entry: "123456789", want: [2]string{"old\n", "older\n"}, wantError: true},
		{name: "resume second", existing: [2]string{"older\n", "new\n"}, entry: "ok\n", want: [2]string{"older\n", "new\nok\n"}, newer: 1},
		{name: "switch back", existing: [2]string{"old\n", "12345678"}, entry: "new\n", want: [2]string{"new\n", "12345678"}, newer: 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "hook")
			for i, suffix := range []string{".1.log", ".2.log"} {
				if err := os.WriteFile(path+suffix, []byte(test.existing[i]), 0600); err != nil {
					t.Fatal(err)
				}
			}
			setLogPairTimes(t, path, test.newer)
			writer, err := openRotatingLogFiles(path, 8)
			if err != nil {
				t.Fatal(err)
			}
			defer writer.Close()
			n, err := writer.Write([]byte(test.entry))
			if (err != nil) != test.wantError {
				t.Fatalf("write = %d, %v; want error %v", n, err, test.wantError)
			}
			if !test.wantError && n != len(test.entry) {
				t.Fatalf("wrote %d bytes, want %d", n, len(test.entry))
			}
			if got := readLogPair(t, path, 8); got != test.want {
				t.Fatalf("contents = %q, want %q", got, test.want)
			}
		})
	}
}

func TestRotatingLogFilesFiveMiBEach(t *testing.T) {
	if maxLogSize != 5*1024*1024 {
		t.Fatalf("log limit = %d, want 5 MiB", maxLogSize)
	}
	path := filepath.Join(t.TempDir(), "hook")
	writer, err := openRotatingLogFiles(path, maxLogSize)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	for _, entry := range [][]byte{
		bytes.Repeat([]byte("a"), maxLogSize-1),
		[]byte("a"),
		[]byte("b"),
		bytes.Repeat([]byte("c"), maxLogSize-1),
	} {
		if _, err := writer.Write(entry); err != nil {
			t.Fatal(err)
		}
	}
	pair := readLogPair(t, path, maxLogSize)
	if len(pair[0]) != maxLogSize || len(pair[1]) != maxLogSize {
		t.Fatalf("sizes = %d + %d; want two 5 MiB files", len(pair[0]), len(pair[1]))
	}
	if pair[0] != strings.Repeat("a", maxLogSize) || pair[1] != "b"+strings.Repeat("c", maxLogSize-1) {
		t.Fatal("rotation lost or corrupted the previous log")
	}
	if _, err := writer.Write([]byte("fresh\n")); err != nil {
		t.Fatal(err)
	}
	after := readLogPair(t, path, maxLogSize)
	if after[0] != "fresh\n" || after[1] != pair[1] {
		t.Fatal("switching back did not clear only the older file")
	}
}

func TestRotatingLogFilesResumeAfterRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hook")
	for cycle, entries := range [][]string{{"12345678", "B"}, {"C", "123456", "D"}, {"E"}} {
		writer, err := openRotatingLogFiles(path, 8)
		if err != nil {
			t.Fatal(err)
		}
		for _, entry := range entries {
			if _, err := writer.Write([]byte(entry)); err != nil {
				writer.Close()
				t.Fatal(err)
			}
		}
		if err := writer.Close(); err != nil {
			t.Fatal(err)
		}
		switch cycle {
		case 0:
			setLogPairTimes(t, path, 1)
		case 1:
			setLogPairTimes(t, path, 0)
		}
	}
	if got, want := readLogPair(t, path, 8), [2]string{"DE", "BC123456"}; got != want {
		t.Fatalf("restart contents = %q, want %q", got, want)
	}
}

func TestRotatingLogFilesRejectInvalidLimit(t *testing.T) {
	for _, limit := range []int64{0, -1} {
		path := filepath.Join(t.TempDir(), "hook")
		if _, err := openRotatingLogFiles(path, limit); err == nil {
			t.Fatalf("accepted limit %d", limit)
		}
		for _, suffix := range []string{".1.log", ".2.log"} {
			if _, err := os.Stat(path + suffix); !os.IsNotExist(err) {
				t.Fatalf("invalid limit created a file: %v", err)
			}
		}
	}
}

func TestRotatingLogFilesReportsIOErrors(t *testing.T) {
	t.Run("open", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "missing", "hook")
		if _, err := openRotatingLogFiles(path, 8); err == nil {
			t.Fatal("ignored open failure")
		}
	})
	t.Run("second open", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "hook")
		if err := os.Mkdir(path+".2.log", 0700); err != nil {
			t.Fatal(err)
		}
		if _, err := openRotatingLogFiles(path, 8); err == nil {
			t.Fatal("ignored second file open failure")
		}
		if err := os.Remove(path + ".1.log"); err != nil {
			t.Fatalf("first file was not released after failed open: %v", err)
		}
	})
	t.Run("closed files", func(t *testing.T) {
		writer, err := openRotatingLogFiles(filepath.Join(t.TempDir(), "hook"), 8)
		if err != nil {
			t.Fatal(err)
		}
		if err := writer.Close(); err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write([]byte("new\n")); !errors.Is(err, os.ErrClosed) {
			t.Fatalf("write error = %v, want closed file", err)
		}
	})
	t.Run("seek", func(t *testing.T) {
		reader, file, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		defer reader.Close()
		defer file.Close()
		writer := &rotatingLogFiles{files: [2]*os.File{file, nil}, maxSize: 8}
		if _, err := writer.Write([]byte("new\n")); err == nil || !strings.Contains(err.Error(), "position log for append") {
			t.Fatalf("seek error = %v", err)
		}
	})
	for _, operation := range []string{"write", "truncate"} {
		t.Run(operation, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "hook")
			writer, err := openRotatingLogFiles(path, 8)
			if err != nil {
				t.Fatal(err)
			}
			defer writer.Close()
			index := 0
			if operation == "truncate" {
				if _, err := writer.Write([]byte("12345678")); err != nil {
					t.Fatal(err)
				}
				index = 1
			}
			if err := writer.files[index].Close(); err != nil {
				t.Fatal(err)
			}
			file, err := os.Open(writer.files[index].Name())
			if err != nil {
				t.Fatal(err)
			}
			writer.files[index] = file
			before := readLogPair(t, path, 8)
			if _, err := writer.Write([]byte("new\n")); err == nil {
				t.Fatalf("ignored %s failure", operation)
			}
			if after := readLogPair(t, path, 8); after != before {
				t.Fatalf("failed %s changed the logs: %q", operation, after)
			}
		})
	}
}

func TestRotatingLogFilesConcurrentLogger(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hook")
	writer, err := openRotatingLogFiles(path, 32)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	logger := log.New(writer, "", 0)
	var group sync.WaitGroup
	for range 100 {
		group.Add(1)
		go func() {
			defer group.Done()
			logger.Print("entry")
		}()
	}
	group.Wait()
	pair := readLogPair(t, path, 32)
	if len(pair[0])+len(pair[1]) <= 32 {
		t.Fatal("rotation did not preserve the previous log")
	}
	for _, data := range pair {
		for _, line := range strings.Split(strings.TrimSuffix(data, "\n"), "\n") {
			if line != "entry" {
				t.Fatalf("corrupt log entry: %q", line)
			}
		}
	}
}

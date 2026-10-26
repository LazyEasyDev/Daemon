package hook

import (
	"errors"
	"fmt"
	"io"
	"os"
	"time"
)

const maxLogSize = 5 * 1024 * 1024

type rotatingLogFiles struct {
	files   [2]*os.File
	current int
	maxSize int64
	closed  bool
}

func openRotatingLogFiles(executablePath string, maxSize int64) (*rotatingLogFiles, error) {
	if maxSize <= 0 {
		return nil, fmt.Errorf("log size limit must be positive")
	}
	writer := &rotatingLogFiles{maxSize: maxSize}
	var newest time.Time
	for i := range writer.files {
		path := fmt.Sprintf("%s.%d.log", executablePath, i+1)
		// Windows append-only handles cannot truncate; Write seeks to the end instead.
		file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0600)
		if err != nil {
			return nil, errors.Join(err, writer.Close())
		}
		writer.files[i] = file
		info, err := file.Stat()
		if err != nil {
			return nil, errors.Join(err, writer.Close())
		}
		if info.Size() > maxSize {
			if err := file.Truncate(0); err != nil {
				return nil, errors.Join(err, writer.Close())
			}
			continue
		}
		if info.Size() > 0 && (newest.IsZero() || info.ModTime().After(newest)) {
			writer.current = i
			newest = info.ModTime()
		}
	}
	return writer, nil
}

func (writer *rotatingLogFiles) Write(data []byte) (n int, err error) {
	// log.Logger ignores write errors; report failures and the entry on stderr.
	defer func() {
		if err != nil {
			fmt.Fprintf(os.Stderr, "cloud hook file logging failed: %v\n", err)
			_, _ = os.Stderr.Write(data)
		}
	}()
	if writer.closed {
		return 0, os.ErrClosed
	}
	if int64(len(data)) > writer.maxSize {
		return 0, fmt.Errorf("log entry exceeds the %d-byte file limit", writer.maxSize)
	}
	info, err := writer.files[writer.current].Stat()
	if err != nil {
		return 0, fmt.Errorf("inspect log size: %w", err)
	}
	if info.Size() > writer.maxSize-int64(len(data)) {
		next := 1 - writer.current
		if err := writer.files[next].Truncate(0); err != nil {
			return 0, fmt.Errorf("clear next log for rotation: %w", err)
		}
		writer.current = next
	}
	file := writer.files[writer.current]
	if _, err := file.Seek(0, io.SeekEnd); err != nil {
		return 0, fmt.Errorf("position log for append: %w", err)
	}
	return file.Write(data)
}

func (writer *rotatingLogFiles) Close() error {
	writer.closed = true
	var err error
	for _, file := range writer.files {
		if file != nil {
			err = errors.Join(err, file.Close())
		}
	}
	return err
}

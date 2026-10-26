package hook

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

type Poll func(context.Context) (string, error)

func Main(provider string, interval time.Duration, newPoll func(*http.Client) Poll) {
	flag.Parse()
	if flag.NArg() != 0 {
		log.Fatal("this executable takes no arguments")
	}
	path, err := os.Executable()
	if err != nil {
		log.Fatal(err)
	}
	files, err := openRotatingLogFiles(path, maxLogSize)
	if err != nil {
		log.Fatalf("open hook log: %v", err)
	}
	defer func() {
		if err := files.Close(); err != nil {
			fmt.Fprintf(os.Stderr, "close hook log: %v\n", err)
		}
	}()
	log.SetOutput(io.MultiWriter(files, os.Stderr))
	self, stopServices, err := prepareServices()
	if err != nil {
		log.Fatal(err)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	log.Printf("%s hook watching; excluding its own service %s", provider, self)
	if err := Run(ctx, interval, newPoll(NewHTTPClient()), stopServices, log.Default()); err != nil {
		log.Fatal(err)
	}
}

func Run(ctx context.Context, interval time.Duration, poll Poll, stop func(context.Context) error, logger *log.Logger) error {
	if interval <= 0 {
		return fmt.Errorf("poll interval must be positive")
	}
	for {
		if ctx.Err() != nil {
			return nil
		}
		notice, err := poll(ctx)
		if ctx.Err() != nil {
			return nil
		}
		switch {
		case err != nil:
			logger.Printf("metadata check failed; retrying in %s: %v", interval, err)
		case notice != "":
			logger.Printf("termination notice: %s; stopping managed applications", notice)
			if err := stop(ctx); err != nil {
				if ctx.Err() != nil {
					return nil
				}
				logger.Printf("application stop failed; not retrying; waiting for cloud termination: %v", err)
			} else {
				logger.Print("managed applications stopped; waiting for cloud termination without acknowledging or extending its deadline")
			}
			// Remain alive after either result so service recovery does not repeat the stop.
			<-ctx.Done()
			return nil
		}
		timer := time.NewTimer(interval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil
		case <-timer.C:
		}
	}
}

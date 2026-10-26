package hook

import (
	"context"
	"fmt"
	"os"
)

func prepareServices() (string, func(context.Context) error, error) {
	if os.Geteuid() != 0 {
		return "", nil, fmt.Errorf("cloud hooks require root privileges on Linux/systemd")
	}
	self, err := ownUnit()
	if err != nil {
		return "", nil, err
	}
	return self, func(ctx context.Context) error {
		return StopServices(ctx, self, runCommand)
	}, nil
}

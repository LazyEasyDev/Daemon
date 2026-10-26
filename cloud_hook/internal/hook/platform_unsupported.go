//go:build !linux && !windows

package hook

import (
	"context"
	"fmt"
)

func prepareServices() (string, func(context.Context) error, error) {
	return "", nil, fmt.Errorf("cloud hooks require Linux/systemd or Windows with the daemon's service wrapper")
}

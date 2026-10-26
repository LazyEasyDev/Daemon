package main

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/LazyEasyDev/Daemon/cloud_hook/internal/hook"
)

func main() {
	hook.Main("AWS ASG", 10*time.Second, func(client *http.Client) hook.Poll {
		metadata := &awsMetadata{client: client, baseURL: "http://169.254.169.254/latest"}
		return metadata.poll
	})
}

type awsMetadata struct {
	client    *http.Client
	baseURL   string
	token     string
	expiresAt time.Time
}

func (metadata *awsMetadata) poll(ctx context.Context) (string, error) {
	for attempt := 0; attempt < 2; attempt++ {
		if metadata.token == "" || time.Now().After(metadata.expiresAt) {
			body, _, err := hook.ReadMetadata(ctx, metadata.client, http.MethodPut, metadata.baseURL+"/api/token",
				map[string]string{"X-aws-ec2-metadata-token-ttl-seconds": "21600"})
			if err != nil {
				return "", fmt.Errorf("get IMDSv2 token: %w", err)
			}
			metadata.token = strings.TrimSpace(string(body))
			if metadata.token == "" {
				return "", fmt.Errorf("IMDSv2 returned an empty token")
			}
			metadata.expiresAt = time.Now().Add(5 * time.Hour)
		}
		body, status, err := hook.ReadMetadata(ctx, metadata.client, http.MethodGet,
			metadata.baseURL+"/meta-data/autoscaling/target-lifecycle-state",
			map[string]string{"X-aws-ec2-metadata-token": metadata.token})
		if status == http.StatusUnauthorized {
			metadata.token = ""
			continue
		}
		if err != nil {
			return "", fmt.Errorf("read ASG target lifecycle state (requires ASG metadata and a termination hook for advance cleanup): %w", err)
		}
		state := strings.TrimSpace(string(body))
		switch state {
		case "Terminated":
			return "AWS ASG target lifecycle state is Terminated", nil
		case "InService", "Detached", "Standby", "Warmed:Running", "Warmed:Stopped", "Warmed:Hibernated", "Warmed:Terminated":
			return "", nil
		default:
			return "", fmt.Errorf("unrecognized ASG target lifecycle state %q", state)
		}
	}
	return "", fmt.Errorf("IMDSv2 rejected refreshed credentials")
}

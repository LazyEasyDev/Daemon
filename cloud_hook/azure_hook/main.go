package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/LazyEasyDev/Daemon/cloud_hook/internal/hook"
)

func main() {
	hook.Main("Azure VMSS", 10*time.Second, func(client *http.Client) hook.Poll {
		metadata := &azureMetadata{client: client, baseURL: "http://169.254.169.254/metadata"}
		return metadata.poll
	})
}

type azureMetadata struct {
	client     *http.Client
	baseURL    string
	name       string
	resourceID string
}

type scheduledEvent struct {
	EventID      string   `json:"EventId"`
	EventType    string   `json:"EventType"`
	EventStatus  string   `json:"EventStatus"`
	ResourceType string   `json:"ResourceType"`
	Resources    []string `json:"Resources"`
	NotBefore    string   `json:"NotBefore"`
}

func (metadata *azureMetadata) poll(ctx context.Context) (string, error) {
	headers := map[string]string{"Metadata": "true"}
	if metadata.name == "" && metadata.resourceID == "" {
		body, _, err := hook.ReadMetadata(ctx, metadata.client, http.MethodGet,
			metadata.baseURL+"/instance/compute?api-version=2021-02-01", headers)
		if err != nil {
			return "", fmt.Errorf("read Azure instance identity: %w", err)
		}
		var identity struct {
			Name       string `json:"name"`
			ResourceID string `json:"resourceId"`
		}
		if err := json.Unmarshal(body, &identity); err != nil {
			return "", fmt.Errorf("decode Azure instance identity: %w", err)
		}
		if strings.TrimSpace(identity.Name) == "" && strings.TrimSpace(identity.ResourceID) == "" {
			return "", fmt.Errorf("Azure instance metadata contains no name or resourceId")
		}
		metadata.name, metadata.resourceID = identity.Name, identity.ResourceID
	}
	body, _, err := hook.ReadMetadata(ctx, metadata.client, http.MethodGet,
		metadata.baseURL+"/scheduledevents?api-version=2020-07-01", headers)
	if err != nil {
		return "", fmt.Errorf("read Azure Scheduled Events: %w", err)
	}
	var document struct {
		Events *[]scheduledEvent `json:"Events"`
	}
	if err := json.Unmarshal(body, &document); err != nil {
		return "", fmt.Errorf("decode Azure Scheduled Events: %w", err)
	}
	if document.Events == nil {
		return "", fmt.Errorf("Azure Scheduled Events response is missing its Events array")
	}
	for _, event := range *document.Events {
		if event.EventType != "Terminate" {
			continue
		}
		affected := false
		for _, resource := range event.Resources {
			if resource != "" && (metadata.name != "" && strings.EqualFold(resource, metadata.name) ||
				metadata.resourceID != "" && strings.EqualFold(resource, metadata.resourceID)) {
				affected = true
				break
			}
		}
		if !affected {
			continue
		}
		if event.EventID == "" || event.ResourceType != "VirtualMachine" {
			return "", fmt.Errorf("malformed Azure Terminate event for this instance")
		}
		switch event.EventStatus {
		case "Scheduled", "Started":
			return fmt.Sprintf("Azure Terminate event %s (NotBefore %s)", event.EventID, event.NotBefore), nil
		default:
			return "", fmt.Errorf("unexpected Azure Terminate event status %q", event.EventStatus)
		}
	}
	return "", nil
}

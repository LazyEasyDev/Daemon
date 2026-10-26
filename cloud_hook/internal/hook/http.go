package hook

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"time"
)

const maxMetadataSize = 1024 * 1024

func NewHTTPClient() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	// Metadata must never be sent through an environment-configured HTTP proxy.
	transport.Proxy = nil
	return &http.Client{
		Transport: transport,
		Timeout:   5 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return fmt.Errorf("metadata redirects are not permitted")
		},
	}
}

func ReadMetadata(ctx context.Context, client *http.Client, method, url string, headers map[string]string) ([]byte, int, error) {
	request, err := http.NewRequestWithContext(ctx, method, url, nil)
	if err != nil {
		return nil, 0, err
	}
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, 0, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, response.StatusCode, fmt.Errorf("metadata %s %s returned HTTP %d", method, request.URL.Path, response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maxMetadataSize+1))
	if err != nil {
		return nil, response.StatusCode, err
	}
	if len(body) > maxMetadataSize {
		return nil, response.StatusCode, fmt.Errorf("metadata response exceeds %d bytes", maxMetadataSize)
	}
	return body, response.StatusCode, nil
}

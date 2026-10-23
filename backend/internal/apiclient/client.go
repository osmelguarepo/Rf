// Package apiclient is a minimal JSON client of the Fuel Rivals API, shared by the admin tool and the load bot.
package apiclient

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Client talks to the API at Base (for example https://play.example.com/api, no trailing slash).
type Client struct {
	Base string
	HTTP *http.Client
}

// New makes a client with a 15 s timeout.
func New(base string) *Client {
	return &Client{Base: strings.TrimRight(base, "/"), HTTP: &http.Client{Timeout: 15 * time.Second}}
}

// Response is an HTTP answer with its body read.
type Response struct {
	Status int
	Header http.Header
	Body   []byte
}

// JSON decodes the body.
func (r *Response) JSON(v any) error { return json.Unmarshal(r.Body, v) }

// OK reports a 2xx status.
func (r *Response) OK() bool { return r.Status >= 200 && r.Status < 300 }

// Err describes a failed answer for messages: the status and the API's error code.
func (r *Response) Err() error {
	var e struct {
		Error   string `json:"error"`
		Message string `json:"message"`
	}
	_ = json.Unmarshal(r.Body, &e)
	if e.Error == "" {
		return fmt.Errorf("HTTP %d: %s", r.Status, strings.TrimSpace(string(r.Body)))
	}
	return fmt.Errorf("HTTP %d %s: %s", r.Status, e.Error, e.Message)
}

// Do sends a request. body may be nil, []byte (sent as is) or anything JSON can encode. token, when set, is the bearer
// token; headers are extra headers (X-Server-Id, X-Replay-Format).
func (c *Client) Do(ctx context.Context, method, path, token string, headers map[string]string, body any) (*Response, error) {
	var rd io.Reader
	switch b := body.(type) {
	case nil:
	case []byte:
		rd = bytes.NewReader(b)
	default:
		raw, err := json.Marshal(b)
		if err != nil {
			return nil, err
		}
		rd = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.Base+path, rd)
	if err != nil {
		return nil, err
	}
	if body != nil {
		if _, raw := body.([]byte); !raw {
			req.Header.Set("Content-Type", "application/json")
		}
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	res, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(res.Body, 64<<20))
	if err != nil {
		return nil, err
	}
	return &Response{Status: res.StatusCode, Header: res.Header, Body: raw}, nil
}

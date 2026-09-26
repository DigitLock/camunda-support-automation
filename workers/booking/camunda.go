package main

// Thin client for the Orchestration Cluster REST API v2 job endpoints (Basic auth).
// Field names verified against the official 8.9 OpenAPI models.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

type camundaClient struct {
	base     string
	user     string
	password string
	http     *http.Client
}

type activatedJob struct {
	JobKey             string         `json:"jobKey"`
	Type               string         `json:"type"`
	Retries            int            `json:"retries"`
	ProcessInstanceKey string         `json:"processInstanceKey"`
	ElementID          string         `json:"elementId"`
	Variables          map[string]any `json:"variables"`
}

func (c *camundaClient) do(ctx context.Context, method, path string, body any, out any) error {
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			return err
		}
	}
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, &buf)
	if err != nil {
		return err
	}
	req.SetBasicAuth(c.user, c.password)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("%s %s: HTTP %d: %s", method, path, resp.StatusCode, msg)
	}
	if out != nil {
		return json.NewDecoder(resp.Body).Decode(out)
	}
	return nil
}

// activateJobs long-polls one job type. requestTimeout is handled server-side;
// the ctx passed in must outlive it.
func (c *camundaClient) activateJobs(ctx context.Context, jobType string, maxJobs int, jobTimeout, requestTimeout time.Duration) ([]activatedJob, error) {
	var result struct {
		Jobs []activatedJob `json:"jobs"`
	}
	err := c.do(ctx, http.MethodPost, "/v2/jobs/activation", map[string]any{
		"type":              jobType,
		"timeout":           jobTimeout.Milliseconds(),
		"maxJobsToActivate": maxJobs,
		"requestTimeout":    requestTimeout.Milliseconds(),
		"worker":            "worker-booking",
	}, &result)
	return result.Jobs, err
}

func (c *camundaClient) completeJob(ctx context.Context, jobKey string, variables map[string]any) error {
	return c.do(ctx, http.MethodPost, "/v2/jobs/"+jobKey+"/completion", map[string]any{
		"variables": variables,
	}, nil)
}

// failJob fails a job with the retries it should have left. retryBackOff (milliseconds,
// 8.9 "Fail job" request body) keeps the job from being re-activated before now + backoff;
// 0 means immediately.
func (c *camundaClient) failJob(ctx context.Context, jobKey string, retries int, retryBackOff time.Duration, errorMessage string) error {
	return c.do(ctx, http.MethodPost, "/v2/jobs/"+jobKey+"/failure", map[string]any{
		"retries":      retries,
		"errorMessage": errorMessage,
		"retryBackOff": retryBackOff.Milliseconds(),
	}, nil)
}

// throwJobError raises a BPMN error. Path is singular: POST /v2/jobs/{jobKey}/error
// (8.9 API reference, "Throw error for job"); the plural form is a 404 that the
// worker used to swallow — see docs/ops/install.md.
func (c *camundaClient) throwJobError(ctx context.Context, jobKey, errorCode, errorMessage string) error {
	return c.do(ctx, http.MethodPost, "/v2/jobs/"+jobKey+"/error", map[string]any{
		"errorCode":    errorCode,
		"errorMessage": errorMessage,
	}, nil)
}

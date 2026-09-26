// Booking worker: serves the booking.change and booking.cancel job types by calling the
// mock Booking API. Error contract (D4-1, docs/design/integrations-v1.md): API 2xx →
// complete with {bookingStatus}; 404 or missing bookingRef → BPMN error BOOKING_NOT_FOUND;
// 5xx / client timeout / transport error → fail with retries-1 and a retry backoff
// (RETRY_BACKOFF, ISO 8601 duration, default PT10S — Phase 6.1 scenario A).
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	maxJobsToActivate  = 5
	jobTimeout         = 60 * time.Second // covers BK-FAIL-TIMEOUT (30 s) with headroom
	requestTimeout     = 10 * time.Second // long-poll duration
	apiTimeout         = 10 * time.Second // booking-api client timeout
	drainTimeout       = 25 * time.Second // < compose stop_grace_period (30 s)
	healthMaxPollAge   = 60 * time.Second
	errBookingNotFound = "BOOKING_NOT_FOUND"
	defaultBackoff     = "PT10S"
)

var lastPoll atomic.Int64 // unix seconds of the last successful activation call

func requireEnv(name string) string {
	v := os.Getenv(name)
	if v == "" {
		fmt.Fprintf(os.Stderr, "error: %s is not set\n", name)
		os.Exit(1)
	}
	return v
}

func logLevel() slog.Level {
	switch strings.ToUpper(os.Getenv("LOG_LEVEL")) {
	case "DEBUG":
		return slog.LevelDebug
	case "WARN":
		return slog.LevelWarn
	case "ERROR":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

type worker struct {
	camunda      *camundaClient
	bookingURL   string
	api          *http.Client
	retryBackoff time.Duration
	inFlight     sync.WaitGroup
}

// parseISODuration accepts the PnDTnHnMnS subset of ISO 8601 durations (e.g. PT10S,
// PT1M30S, P1D). Fractions are not supported; a negative or empty value is an error.
func parseISODuration(v string) (time.Duration, error) {
	if len(v) < 3 || v[0] != 'P' {
		return 0, fmt.Errorf("%q is not an ISO 8601 duration (expected e.g. PT10S)", v)
	}
	var total time.Duration
	inTime := false
	num := ""
	for _, r := range v[1:] {
		switch {
		case r >= '0' && r <= '9':
			num += string(r)
		case r == 'T':
			inTime = true
		default:
			if num == "" {
				return 0, fmt.Errorf("%q: missing number before %q", v, string(r))
			}
			n, _ := strconv.Atoi(num)
			num = ""
			switch {
			case r == 'D' && !inTime:
				total += time.Duration(n) * 24 * time.Hour
			case r == 'H' && inTime:
				total += time.Duration(n) * time.Hour
			case r == 'M' && inTime:
				total += time.Duration(n) * time.Minute
			case r == 'S' && inTime:
				total += time.Duration(n) * time.Second
			default:
				return 0, fmt.Errorf("%q: unsupported designator %q (use D, or T with H/M/S)", v, string(r))
			}
		}
	}
	if num != "" {
		return 0, fmt.Errorf("%q: trailing number without designator", v)
	}
	return total, nil
}

// fail reports one failed attempt: retries-1, the configured backoff, an errorMessage
// that names the call and the retries left (it is the incident text in Operate once
// retries are exhausted), and one WARN log line with the fields an operator needs to
// find the instance and the task (Phase 6.1 scenario A).
func (w *worker) fail(ctx context.Context, log *slog.Logger, job activatedJob, ref, action, cause string, httpStatus int) {
	left := job.Retries - 1
	if left < 0 {
		left = 0
	}
	call := fmt.Sprintf("POST /bookings/%s/%s", ref, action)
	msg := fmt.Sprintf("booking-api %s on %s (retries left: %d)", cause, call, left)
	log.Warn("failed",
		"processInstanceKey", job.ProcessInstanceKey, "elementId", job.ElementID,
		"httpStatus", httpStatus, "retriesLeft", left, "retryBackOff", w.retryBackoff.String(),
		"reason", msg)
	w.report(ctx, log, job, "failure", w.camunda.failJob(ctx, job.JobKey, left, w.retryBackoff, msg))
}

// handle processes one job and reports the outcome to Camunda.
func (w *worker) handle(ctx context.Context, job activatedJob) {
	defer w.inFlight.Done()
	log := slog.With("jobKey", job.JobKey, "type", job.Type)

	ref, _ := job.Variables["bookingRef"].(string)
	log = log.With("bookingRef", ref)
	if ref == "" {
		log.Info("error", "errorCode", errBookingNotFound, "reason", "bookingRef missing or null")
		w.report(ctx, log, job, "error", w.camunda.throwJobError(ctx, job.JobKey, errBookingNotFound,
			"bookingRef missing or null (no booking-api call made)"))
		return
	}

	action := "change"
	if job.Type == "booking.cancel" {
		action = "cancel"
	}
	apiCtx, cancel := context.WithTimeout(ctx, apiTimeout)
	defer cancel()
	req, _ := http.NewRequestWithContext(apiCtx, http.MethodPost,
		fmt.Sprintf("%s/bookings/%s/%s", w.bookingURL, ref, action), nil)
	resp, err := w.api.Do(req)

	switch {
	case err != nil && apiCtx.Err() == context.DeadlineExceeded: // client timeout (apiTimeout)
		w.fail(ctx, log, job, ref, action, fmt.Sprintf("timeout after %s", apiTimeout), 0)
	case err != nil: // transport error (connection refused, DNS, reset)
		w.fail(ctx, log, job, ref, action, "transport error: "+err.Error(), 0)
	case resp.StatusCode == http.StatusNotFound:
		drain(resp)
		log.Info("error", "errorCode", errBookingNotFound)
		// the message reaches the process as errorMessage through the output mappings of
		// the v9 boundary events (throw-error payload, Phase 6.2), and Operate when
		// nothing catches the error
		w.report(ctx, log, job, "error", w.camunda.throwJobError(ctx, job.JobKey, errBookingNotFound,
			fmt.Sprintf("booking %s not found (HTTP 404 on POST /bookings/%s/%s)", ref, ref, action)))
	case resp.StatusCode >= 500:
		drain(resp)
		w.fail(ctx, log, job, ref, action, fmt.Sprintf("HTTP %d", resp.StatusCode), resp.StatusCode)
	default:
		var booking struct {
			Status   string  `json:"status"`
			Value    float64 `json:"value"`
			Currency string  `json:"currency"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&booking)
		resp.Body.Close()
		variables := map[string]any{"bookingStatus": booking.Status}
		if job.Type == "booking.cancel" {
			// refund contract (docs/design/integrations-v1.md): the refund equals the
			// booking's value in the booking's currency; conversion to the customer's
			// currency happens in the process (convert-refund)
			variables["refundAmount"] = booking.Value
			variables["refundCurrency"] = booking.Currency
		}
		log.Info("completed", "bookingStatus", booking.Status)
		w.report(ctx, log, job, "completion", w.camunda.completeJob(ctx, job.JobKey, variables))
	}
}

func drain(resp *http.Response) {
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 512))
	resp.Body.Close()
}

// report handles a failed job-lifecycle call. Logging alone is not enough: the job would
// time out, be re-activated and hit the same failure forever with a green instance in
// Operate (seen live with the wrong error path — docs/ops/install.md). So a failed
// error/completion call is turned into a failure with retries=0, which raises an
// incident that names the original problem. A failed failure call can only be logged.
func (w *worker) report(ctx context.Context, log *slog.Logger, job activatedJob, call string, err error) {
	if err == nil || ctx.Err() != nil {
		return
	}
	log.Error("job lifecycle call failed", "call", call, "error", err.Error())
	if call == "failure" {
		return
	}
	msg := fmt.Sprintf("job %s call failed, raising incident instead: %s", call, err.Error())
	if ferr := w.camunda.failJob(ctx, job.JobKey, 0, 0, msg); ferr != nil {
		log.Error("job lifecycle call failed", "call", "failure (fallback)", "error", ferr.Error())
	}
}

// poll long-polls one job type until ctx is cancelled.
func (w *worker) poll(ctx context.Context, jobType string) {
	for ctx.Err() == nil {
		jobs, err := w.camunda.activateJobs(ctx, jobType, maxJobsToActivate, jobTimeout, requestTimeout)
		if err != nil {
			if ctx.Err() == nil {
				slog.Warn("activation failed", "type", jobType, "error", err.Error())
				time.Sleep(2 * time.Second)
			}
			continue
		}
		lastPoll.Store(time.Now().Unix())
		for _, job := range jobs {
			slog.Info("activated", "jobKey", job.JobKey, "type", job.Type, "bookingRef", job.Variables["bookingRef"])
			w.inFlight.Add(1)
			go w.handle(context.WithoutCancel(ctx), job)
		}
	}
}

func healthServer() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		if time.Since(time.Unix(lastPoll.Load(), 0)) > healthMaxPollAge {
			http.Error(w, "last successful poll too old", http.StatusServiceUnavailable)
			return
		}
		fmt.Fprintln(w, "ok")
	})
	_ = http.ListenAndServe(":8081", mux)
}

func main() {
	check := flag.Bool("check", false, "healthcheck mode: probe /healthz and exit")
	flag.Parse()
	if *check {
		resp, err := http.Get("http://127.0.0.1:8081/healthz")
		if err != nil || resp.StatusCode != http.StatusOK {
			os.Exit(1)
		}
		os.Exit(0)
	}

	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: logLevel()})))

	backoffSpec := os.Getenv("RETRY_BACKOFF")
	if backoffSpec == "" {
		backoffSpec = defaultBackoff
	}
	backoff, err := parseISODuration(backoffSpec)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: RETRY_BACKOFF %v\n", err)
		os.Exit(1)
	}

	w := &worker{
		camunda: &camundaClient{
			base:     strings.TrimRight(requireEnv("CAMUNDA_BASE_URL"), "/"),
			user:     requireEnv("CAMUNDA_USER"),
			password: requireEnv("CAMUNDA_PASSWORD"),
			// long poll runs up to requestTimeout server-side; leave headroom
			http: &http.Client{Timeout: requestTimeout + 5*time.Second},
		},
		bookingURL:   strings.TrimRight(requireEnv("BOOKING_API_URL"), "/"),
		api:          &http.Client{Timeout: apiTimeout},
		retryBackoff: backoff,
	}
	lastPoll.Store(time.Now().Unix()) // grace until the first real poll

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	go healthServer()
	for _, jobType := range []string{"booking.change", "booking.cancel"} {
		go w.poll(ctx, jobType)
	}
	slog.Info("worker-booking polling", "types", "booking.change,booking.cancel", "retryBackOff", backoff.String())

	<-ctx.Done()
	slog.Info("shutdown: activation stopped, waiting for in-flight jobs", "limit", drainTimeout.String())
	done := make(chan struct{})
	go func() { w.inFlight.Wait(); close(done) }()
	select {
	case <-done:
		slog.Info("shutdown complete")
	case <-time.After(drainTimeout):
		slog.Warn("shutdown: drain timeout reached, exiting with jobs in flight")
	}
}

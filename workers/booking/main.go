// Booking worker: serves the booking.change and booking.cancel job types by calling the
// mock Booking API. Error contract (D4-1, docs/design/integrations-v1.md): API 2xx →
// complete with {bookingStatus}; 404 or missing bookingRef → BPMN error BOOKING_NOT_FOUND;
// 5xx / client timeout → fail with retries-1.
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
	camunda    *camundaClient
	bookingURL string
	api        *http.Client
	inFlight   sync.WaitGroup
}

// handle processes one job and reports the outcome to Camunda.
func (w *worker) handle(ctx context.Context, job activatedJob) {
	defer w.inFlight.Done()
	log := slog.With("jobKey", job.JobKey, "type", job.Type)

	ref, _ := job.Variables["bookingRef"].(string)
	log = log.With("bookingRef", ref)
	if ref == "" {
		log.Info("error", "errorCode", errBookingNotFound, "reason", "bookingRef missing or null")
		w.report(ctx, log, job, "error", w.camunda.throwJobError(ctx, job.JobKey, errBookingNotFound, "bookingRef is missing or null"))
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
	case err != nil: // network error or client timeout
		log.Info("failed", "retriesLeft", job.Retries-1, "reason", err.Error())
		w.report(ctx, log, job, "failure", w.camunda.failJob(ctx, job.JobKey, job.Retries-1, "booking-api call failed: "+err.Error()))
	case resp.StatusCode == http.StatusNotFound:
		drain(resp)
		log.Info("error", "errorCode", errBookingNotFound)
		w.report(ctx, log, job, "error", w.camunda.throwJobError(ctx, job.JobKey, errBookingNotFound, "booking not found: "+ref))
	case resp.StatusCode >= 500:
		drain(resp)
		log.Info("failed", "retriesLeft", job.Retries-1, "reason", fmt.Sprintf("booking-api HTTP %d", resp.StatusCode))
		w.report(ctx, log, job, "failure", w.camunda.failJob(ctx, job.JobKey, job.Retries-1, fmt.Sprintf("booking-api returned HTTP %d", resp.StatusCode)))
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
	if ferr := w.camunda.failJob(ctx, job.JobKey, 0, msg); ferr != nil {
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

	w := &worker{
		camunda: &camundaClient{
			base:     strings.TrimRight(requireEnv("CAMUNDA_BASE_URL"), "/"),
			user:     requireEnv("CAMUNDA_USER"),
			password: requireEnv("CAMUNDA_PASSWORD"),
			// long poll runs up to requestTimeout server-side; leave headroom
			http: &http.Client{Timeout: requestTimeout + 5*time.Second},
		},
		bookingURL: strings.TrimRight(requireEnv("BOOKING_API_URL"), "/"),
		api:        &http.Client{Timeout: apiTimeout},
	}
	lastPoll.Store(time.Now().Unix()) // grace until the first real poll

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	go healthServer()
	for _, jobType := range []string{"booking.change", "booking.cancel"} {
		go w.poll(ctx, jobType)
	}
	slog.Info("worker-booking polling", "types", "booking.change,booking.cancel")

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

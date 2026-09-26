// Mock Booking API for the support-automation stand (Phase 4).
// In-memory bookings with deterministic failures by booking-id convention, plus a runtime
// outage toggle (/admin/fault, Phase 6.1 scenario A2) — see README.md.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"
)

type Booking struct {
	ID         string  `json:"id"`
	CustomerID string  `json:"customerId"`
	Value      float64 `json:"value"`
	Currency   string  `json:"currency"`
	BookedAt   string  `json:"bookedAt"`
	TravelDate string  `json:"travelDate"`
	Status     string  `json:"status"`
}

var (
	mu       sync.Mutex
	bookings = map[string]*Booking{
		"BK-77": {ID: "BK-77", CustomerID: "C-1001", Value: 540.0, Currency: "EUR", BookedAt: "2026-08-30", TravelDate: "2026-10-14", Status: "confirmed"},
		"BK-81": {ID: "BK-81", CustomerID: "C-1002", Value: 320.5, Currency: "EUR", BookedAt: "2026-09-02", TravelDate: "2026-10-02", Status: "confirmed"},
		"BK-90": {ID: "BK-90", CustomerID: "C-1004", Value: 210.0, Currency: "EUR", BookedAt: "2026-09-10", TravelDate: "2026-11-20", Status: "confirmed"},
		// values/currencies aligned with tests/e2e/tickets.json (BK-1001 ↔ T-1007)
		"BK-1001": {ID: "BK-1001", CustomerID: "C-2001", Value: 1050.0, Currency: "USD", BookedAt: "2026-09-15", TravelDate: "2026-12-05", Status: "confirmed"},
	}
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// fault is the runtime outage toggle: while active, every /bookings/* request answers
// with fault.status (default 503). /healthz and /admin/* are unaffected on purpose — the
// scenario is "the dependency's application fails", not "its container died", so the
// booking-api container stays healthy in `docker compose ps`.
type faultState struct {
	Active bool   `json:"active"`
	Status int    `json:"status"`
	Since  string `json:"since,omitempty"`
}

var (
	faultMu sync.RWMutex
	fault   faultState
)

func currentFault() faultState {
	faultMu.RLock()
	defer faultMu.RUnlock()
	return fault
}

// injectFault answers the request with the configured outage status. Returns true when
// the request is done.
func injectFault(w http.ResponseWriter) bool {
	f := currentFault()
	if !f.Active {
		return false
	}
	writeError(w, f.Status, fmt.Sprintf("injected outage (admin/fault, since %s)", f.Since))
	return true
}

func faultStatus(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, currentFault())
}

// faultOn: PUT /admin/fault?status=503 (status optional, 500..599)
func faultOn(w http.ResponseWriter, r *http.Request) {
	status := http.StatusServiceUnavailable
	if q := r.URL.Query().Get("status"); q != "" {
		n, err := strconv.Atoi(q)
		if err != nil || n < 500 || n > 599 {
			writeError(w, http.StatusBadRequest, "status must be an integer in 500..599")
			return
		}
		status = n
	}
	faultMu.Lock()
	fault = faultState{Active: true, Status: status, Since: time.Now().UTC().Format(time.RFC3339)}
	f := fault
	faultMu.Unlock()
	log.Printf("fault ON: all /bookings/* requests answer HTTP %d", f.Status)
	writeJSON(w, http.StatusOK, f)
}

// faultOff: DELETE /admin/fault
func faultOff(w http.ResponseWriter, _ *http.Request) {
	faultMu.Lock()
	fault = faultState{}
	faultMu.Unlock()
	log.Println("fault OFF")
	writeJSON(w, http.StatusOK, faultState{})
}

// injectFailure handles the BK-FAIL-* convention. Returns true when the request is done.
func injectFailure(w http.ResponseWriter, id string) bool {
	switch id {
	case "BK-FAIL-500":
		writeError(w, http.StatusInternalServerError, "injected failure (BK-FAIL-500)")
		return true
	case "BK-FAIL-TIMEOUT":
		// The caller is expected to hit its client timeout first.
		time.Sleep(30 * time.Second)
		writeError(w, http.StatusInternalServerError, "injected timeout elapsed (BK-FAIL-TIMEOUT)")
		return true
	}
	return false
}

func getBooking(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if injectFault(w) || injectFailure(w, id) {
		return
	}
	mu.Lock()
	defer mu.Unlock()
	b, ok := bookings[id]
	if !ok {
		writeError(w, http.StatusNotFound, "booking not found: "+id)
		return
	}
	writeJSON(w, http.StatusOK, b)
}

func mutateBooking(newStatus string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if injectFault(w) || injectFailure(w, id) {
			return
		}
		var body struct {
			TravelDate string `json:"travelDate"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body) // empty body is fine
		mu.Lock()
		defer mu.Unlock()
		b, ok := bookings[id]
		if !ok {
			writeError(w, http.StatusNotFound, "booking not found: "+id)
			return
		}
		if newStatus == "changed" && body.TravelDate != "" {
			b.TravelDate = body.TravelDate
		}
		b.Status = newStatus
		writeJSON(w, http.StatusOK, b)
	}
}

func main() {
	check := flag.Bool("check", false, "healthcheck mode: probe /healthz and exit")
	faultCmd := flag.String("fault", "", "operator mode (scratch image, no curl): on | on:<status> | off | status — calls /admin/fault of the running service and exits")
	flag.Parse()
	if *check {
		resp, err := http.Get("http://127.0.0.1:8080/healthz")
		if err != nil || resp.StatusCode != http.StatusOK {
			os.Exit(1)
		}
		os.Exit(0)
	}
	if *faultCmd != "" {
		os.Exit(runFaultCommand(*faultCmd))
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /bookings/{id}", getBooking)
	mux.HandleFunc("POST /bookings/{id}/change", mutateBooking("changed"))
	mux.HandleFunc("POST /bookings/{id}/cancel", mutateBooking("cancelled"))
	mux.HandleFunc("GET /admin/fault", faultStatus)
	mux.HandleFunc("PUT /admin/fault", faultOn)
	mux.HandleFunc("DELETE /admin/fault", faultOff)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "ok")
	})

	log.Println("booking-api listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", mux))
}

// runFaultCommand implements `/app -fault on|on:<status>|off|status` for operators: the
// image is scratch (no shell, no curl) and the port is not published, so the binary
// itself is the client — same idea as -check. Prints the resulting fault state as JSON.
func runFaultCommand(cmd string) int {
	const base = "http://127.0.0.1:8080/admin/fault"
	var req *http.Request
	var err error
	switch {
	case cmd == "status":
		req, err = http.NewRequest(http.MethodGet, base, nil)
	case cmd == "off":
		req, err = http.NewRequest(http.MethodDelete, base, nil)
	case cmd == "on":
		req, err = http.NewRequest(http.MethodPut, base, nil)
	case len(cmd) > 3 && cmd[:3] == "on:":
		req, err = http.NewRequest(http.MethodPut, base+"?status="+cmd[3:], nil)
	default:
		fmt.Fprintln(os.Stderr, "usage: -fault on | on:<status> | off | status")
		return 2
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		return 1
	}
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		return 1
	}
	defer resp.Body.Close()
	var body map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&body)
	out, _ := json.Marshal(body)
	fmt.Println(string(out))
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}

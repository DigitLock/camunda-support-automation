// Mock Booking API for the support-automation stand (Phase 4).
// In-memory bookings with deterministic failures by booking-id convention — see README.md.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
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
		"BK-77":   {ID: "BK-77", CustomerID: "C-1001", Value: 540.0, Currency: "EUR", BookedAt: "2026-08-30", TravelDate: "2026-10-14", Status: "confirmed"},
		"BK-81":   {ID: "BK-81", CustomerID: "C-1002", Value: 320.5, Currency: "EUR", BookedAt: "2026-09-02", TravelDate: "2026-10-02", Status: "confirmed"},
		"BK-90":   {ID: "BK-90", CustomerID: "C-1004", Value: 210.0, Currency: "EUR", BookedAt: "2026-09-10", TravelDate: "2026-11-20", Status: "confirmed"},
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
	if injectFailure(w, id) {
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
		if injectFailure(w, id) {
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
	flag.Parse()
	if *check {
		resp, err := http.Get("http://127.0.0.1:8080/healthz")
		if err != nil || resp.StatusCode != http.StatusOK {
			os.Exit(1)
		}
		os.Exit(0)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /bookings/{id}", getBooking)
	mux.HandleFunc("POST /bookings/{id}/change", mutateBooking("changed"))
	mux.HandleFunc("POST /bookings/{id}/cancel", mutateBooking("cancelled"))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "ok")
	})

	log.Println("booking-api listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", mux))
}

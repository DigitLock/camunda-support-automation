// FX gateway: a stable /convert contract for the Camunda REST connector, backed by a
// pluggable rate provider. Current provider: frankfurter.app (ECB reference rates) —
// swapping it for the shared currency-rate-service is parked in docs/backlog.md and
// must not change the /convert contract.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"time"
)

// RateProvider returns the current rate for one currency pair and the date it applies to.
type RateProvider interface {
	Rate(ctx context.Context, from, to string) (rate float64, asOf string, err error)
}

type frankfurter struct {
	base   string
	client *http.Client
}

func (f *frankfurter) Rate(ctx context.Context, from, to string) (float64, string, error) {
	url := fmt.Sprintf("%s/latest?from=%s&to=%s", f.base, from, to)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, "", err
	}
	resp, err := f.client.Do(req)
	if err != nil {
		return 0, "", fmt.Errorf("provider request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return 0, "", fmt.Errorf("provider returned %d: %s", resp.StatusCode, body)
	}
	var payload struct {
		Date  string             `json:"date"`
		Rates map[string]float64 `json:"rates"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return 0, "", fmt.Errorf("provider response not parseable: %w", err)
	}
	rate, ok := payload.Rates[to]
	if !ok {
		return 0, "", fmt.Errorf("pair %s/%s not in provider response", from, to)
	}
	return rate, payload.Date, nil
}

var currencyRe = regexp.MustCompile(`^[A-Z]{3}$`)

func convertHandler(provider RateProvider) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		from, to := q.Get("from"), q.Get("to")
		if !currencyRe.MatchString(from) || !currencyRe.MatchString(to) {
			writeError(w, http.StatusBadRequest, "from and to must be 3-letter uppercase currency codes")
			return
		}
		amount, err := strconv.ParseFloat(q.Get("amount"), 64)
		if err != nil || amount <= 0 {
			writeError(w, http.StatusBadRequest, "amount must be a positive number")
			return
		}
		var (
			rate float64
			asOf string
		)
		if from == to {
			// same-currency short-circuit: no provider call (D4, docs/design/integrations-v1.md)
			rate, asOf = 1, time.Now().UTC().Format("2006-01-02")
		} else {
			ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
			defer cancel()
			var err error
			rate, asOf, err = provider.Rate(ctx, from, to)
			if err != nil {
				writeError(w, http.StatusBadGateway, err.Error())
				return
			}
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"from":      from,
			"to":        to,
			"amount":    amount,
			"rate":      rate,
			"converted": math.Round(amount*rate*100) / 100,
			"asOf":      asOf,
		})
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
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

	base := os.Getenv("FRANKFURTER_BASE_URL")
	if base == "" {
		base = "https://api.frankfurter.app"
	}
	provider := &frankfurter{base: base, client: &http.Client{Timeout: 10 * time.Second}}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /convert", convertHandler(provider))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "ok")
	})

	log.Println("fx-gateway listening on :8080, provider:", base)
	log.Fatal(http.ListenAndServe(":8080", mux))
}

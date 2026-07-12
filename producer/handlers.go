package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	nats "github.com/nats-io/nats.go"

	"github.com/go-chi/chi/v5"
)

// healthHandler returns an HTTP handler that reports the producer's health.
// Responds 503 if the NATS connection is not in CONNECTED state.
func healthHandler(client *rpcClient) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		status := http.StatusOK
		payload := map[string]any{
			"status":  "healthy",
			"service": serviceName,
			"nats":    "ok",
		}
		if client.nc.Status() != nats.CONNECTED {
			status = http.StatusServiceUnavailable
			payload["status"] = "unhealthy"
			payload["nats"] = "disconnected"
		}
		writeJSON(w, status, payload)
	}
}

// proxyHandler forwards an HTTP request to the given NATS subject and writes the
// consumer's JSON response back. The subject is fixed at registration time so
// each chi route maps to exactly one NATS endpoint with no path-to-subject
// derivation at request time.
//
// Returns 503 when no consumer is subscribed, 504 on RPC timeout.
func proxyHandler(client *rpcClient, m *metrics, logger *slog.Logger, subject string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path

		started := time.Now()
		defer func() {
			m.httpDuration.WithLabelValues(r.Method, path).Observe(time.Since(started).Seconds())
		}()

		payload, err := parsePayload(r)
		if err != nil {
			m.httpRequests.WithLabelValues(r.Method, path, "400").Inc()
			writeJSON(w, http.StatusBadRequest, map[string]string{"detail": "Invalid JSON body"})
			return
		}

		session := r.Header.Get("X-Session")
		adminSecret := r.Header.Get("X-Admin-Secret")
		req := rpcRequest{Payload: payload}

		resp, err := client.call(r.Context(), subject, req, session, adminSecret, m)
		if err != nil {
			httpStatus := http.StatusBadGateway
			detail := err.Error()
			if errors.Is(err, errServiceUnavailable) {
				httpStatus = http.StatusServiceUnavailable
				detail = "Service unavailable"
			} else if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
				httpStatus = http.StatusGatewayTimeout
				detail = "Gateway timeout"
			}
			m.httpRequests.WithLabelValues(r.Method, path, strconv.Itoa(httpStatus)).Inc()
			logger.Error("producer_error",
				"path", path,
				"subject", subject,
				"error", err.Error(),
			)
			writeJSON(w, httpStatus, map[string]string{"detail": detail})
			return
		}

		m.httpRequests.WithLabelValues(r.Method, path, strconv.Itoa(resp.Status)).Inc()
		// 204 No Content must not include a body (RFC 9110 §15.3.5).
		if resp.Status == http.StatusNoContent {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if len(resp.Body) == 0 {
			resp.Body = json.RawMessage(`{}`)
		}
		writeRawJSON(w, resp.Status, resp.Body)
	}
}

// injectPathParam returns a middleware-style wrapper that reads a chi URL param
// (by paramName) and injects it as a query-string key (as queryKey) before the
// request reaches the underlying handler. Used to bridge /resource/{id} chi routes
// into handlers that read the ID from query params (parsePayload GET branch).
func injectPathParam(paramName, queryKey string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if id := chi.URLParam(r, paramName); id != "" {
			q := r.URL.Query()
			q.Set(queryKey, id)
			r.URL.RawQuery = q.Encode()
		}
		next(w, r)
	}
}

// parsePayload extracts the request body for mutation methods (POST/PUT/PATCH) and
// query parameters for GET requests, normalised to a JSON-serialisable value.
// An empty or missing body returns an empty map rather than an error.
func parsePayload(r *http.Request) (any, error) {
	switch r.Method {
	case http.MethodPost, http.MethodPut, http.MethodPatch:
		if r.Body == nil {
			return map[string]any{}, nil
		}
		defer r.Body.Close()

		var payload any
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			if errors.Is(err, io.EOF) {
				return map[string]any{}, nil
			}
			return nil, err
		}
		if payload == nil {
			return map[string]any{}, nil
		}
		return payload, nil

	case http.MethodGet:
		query := r.URL.Query() // parse once
		payload := make(map[string]string, len(query))
		for key, values := range query {
			if len(values) > 0 {
				payload[key] = values[0]
			}
		}
		return payload, nil

	default:
		return map[string]any{}, nil
	}
}

// writeJSON marshals payload to JSON and writes it as the HTTP response.
// Falls back to a 500 plain-text error if marshalling fails.
func writeJSON(w http.ResponseWriter, status int, payload any) {
	data, err := json.Marshal(payload)
	if err != nil {
		http.Error(w, `{"detail":"internal server error"}`, http.StatusInternalServerError)
		return
	}
	writeRawJSON(w, status, data)
}

// writeRawJSON writes a pre-marshalled JSON byte slice as the HTTP response.
func writeRawJSON(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

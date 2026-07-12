package main

import (
	"github.com/prometheus/client_golang/prometheus"
)

// metrics holds all Prometheus instruments for the api-producer process.
// HTTP instruments track inbound requests; RPC instruments track outbound NATS calls.
type metrics struct {
	httpRequests     *prometheus.CounterVec
	httpDuration     *prometheus.HistogramVec
	rpcRequests      *prometheus.CounterVec
	rpcRoundtrip     *prometheus.HistogramVec
	rpcTimeouts      prometheus.Counter
	rpcPublishErrors prometheus.Counter
	rpcInflight      prometheus.Gauge
	natsConnected    prometheus.Gauge
}

// newMetrics creates and registers all producer Prometheus collectors.
// Panics if any metric name collides with an already-registered collector.
func newMetrics() *metrics {
	m := &metrics{
		httpRequests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total HTTP requests handled by api-producer.",
		}, []string{"method", "route", "status"}),
		httpDuration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request duration.",
			Buckets: prometheus.DefBuckets,
		}, []string{"method", "route"}),
		rpcRequests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "rpc_requests_total",
			Help: "Total RPC requests published.",
		}, []string{"queue", "status"}),
		rpcRoundtrip: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "rpc_roundtrip_duration_seconds",
			Help:    "RPC roundtrip duration.",
			Buckets: prometheus.DefBuckets,
		}, []string{"queue"}),
		rpcTimeouts: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "rpc_timeouts_total",
			Help: "Total RPC timeout count.",
		}),
		rpcPublishErrors: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "rpc_publish_errors_total",
			Help: "Total RPC publish errors (ErrNoResponders, marshal errors, NATS errors).",
		}),
		rpcInflight: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "rpc_inflight_requests",
			Help: "Current in-flight RPC requests.",
		}),
		natsConnected: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "nats_connected",
			Help: "Whether the NATS connection is active (1) or not (0).",
		}),
	}

	prometheus.MustRegister(
		m.httpRequests,
		m.httpDuration,
		m.rpcRequests,
		m.rpcRoundtrip,
		m.rpcTimeouts,
		m.rpcPublishErrors,
		m.rpcInflight,
		m.natsConnected,
	)
	return m
}

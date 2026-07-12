package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"os"
	"strconv"
	"time"

	nats "github.com/nats-io/nats.go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

// errServiceUnavailable is returned by call() when no consumers are subscribed
// to the target subject (NATS ErrNoResponders). Maps to HTTP 503.
var errServiceUnavailable = errors.New("service unavailable: no responders")

// rpcRequest is the JSON body sent to every consumer endpoint.
// Action is no longer needed — the NATS subject encodes it (Phase 6b).
// Auth headers (x-session, x-admin-secret) travel as NATS message headers.
type rpcRequest struct {
	Payload any `json:"payload"`
}

// natsTraceSampleRate controls the fraction of requests that carry a
// Nats-Trace-Dest header for NATS 2.11 server-level distributed tracing.
// Default: 1% (0.01). Override with NATS_TRACE_SAMPLE_RATE env var (0–1).
// Set to "1" to trace every request (useful in staging).
// Set to "0" to disable entirely.
//
// When the header is present, the NATS server appends a trace event to the
// subject named in the header value, recording latency at each hop across the
// cluster. The header is stripped before delivery to the consumer — it has
// no effect on handler code.
var natsTraceSampleRate = func() float64 {
	if s := os.Getenv("NATS_TRACE_SAMPLE_RATE"); s != "" {
		if v, err := strconv.ParseFloat(s, 64); err == nil && v >= 0 && v <= 1 {
			return v
		}
	}
	return 0.01 // 1 % default
}()

// traceDestSubject is the NATS subject that receives tracing events when
// Nats-Trace-Dest is set. The subject is hardcoded to a single well-known
// location so ops can subscribe once and see all sampled traces:
//
//	nats sub 'banking.trace.rpc.*'
const traceDestSubject = "banking.trace.rpc"

type rpcResponse struct {
	Status int             `json:"status"`
	Body   json.RawMessage `json:"body"`
}

type rpcClient struct {
	nc              *nats.Conn
	logger          *slog.Logger
	tracer          trace.Tracer
	responseTimeout time.Duration
}

// newRPCClient connects to NATS with production-grade options and returns a ready client.
// Exits the process on connection failure (see RetryOnFailedConnect comment inside).
func newRPCClient(cfg config, logger *slog.Logger) *rpcClient {
	nc, err := nats.Connect(cfg.NATSURL,
		nats.Name(serviceName),                                      // visible in /connz monitoring
		nats.MaxReconnects(-1),                                      // never give up — producer must stay alive
		nats.ReconnectWait(2*time.Second),
		nats.ReconnectJitter(500*time.Millisecond, 2*time.Second),   // prevent thundering herd on mass restart
		nats.RetryOnFailedConnect(true),                             // survive container startup races
		nats.PingInterval(20*time.Second),                           // detect silent TCP hangs within ~100 s
		nats.MaxPingsOutstanding(5),
		nats.ReconnectBufSize(8*1024*1024),                          // 8 MB publish buffer during reconnect
		nats.DisconnectErrHandler(func(_ *nats.Conn, err error) {
			logger.Error("nats_disconnected", "error", err)
		}),
		nats.ReconnectHandler(func(conn *nats.Conn) {
			logger.Info("nats_reconnected", "url", conn.ConnectedUrl())
		}),
		nats.ClosedHandler(func(_ *nats.Conn) {
			logger.Error("nats_connection_permanently_closed")
		}),
	)
	if err != nil {
		// RetryOnFailedConnect=true: Connect only returns an error when
		// MaxReconnects is exhausted — unreachable with -1. Exit is safe here.
		logger.Error("nats_connect_fatal", "error", err.Error())
		os.Exit(1)
	}
	return &rpcClient{
		nc:              nc,
		logger:          logger,
		tracer:          otel.Tracer(serviceName),
		responseTimeout: cfg.ResponseTimeout,
	}
}

// call publishes req to subject and blocks until a reply arrives or the context
// expires. Returns errServiceUnavailable (→ HTTP 503) when no consumers are
// subscribed to the subject (NATS ErrNoResponders).
// session and adminSecret travel as NATS message headers, not in the JSON body.
func (c *rpcClient) call(ctx context.Context, subject string, req rpcRequest, session, adminSecret string, m *metrics) (rpcResponse, error) {
	if err := ctx.Err(); err != nil {
		return rpcResponse{}, fmt.Errorf("call: context already done: %w", err)
	}

	body, err := json.Marshal(req)
	if err != nil {
		return rpcResponse{}, fmt.Errorf("marshal rpc request: %w", err)
	}

	ctx, span := c.tracer.Start(ctx, "rpc.request", trace.WithAttributes(
		attribute.String("messaging.system", "nats"),
		attribute.String("messaging.destination.name", subject),
	))
	defer span.End()

	m.rpcInflight.Inc()
	defer m.rpcInflight.Dec()
	started := time.Now()

	waitCtx, cancel := context.WithTimeout(ctx, c.responseTimeout)
	defer cancel()

	// Build NATS message headers. Auth headers always present; OTel W3C
	// traceparent injected so consumers can continue the same trace, and the
	// Nats-Trace-Dest tracing header added on a sampled basis for NATS 2.11
	// server-level distributed tracing.
	hdr := nats.Header{
		"x-session":      []string{session},
		"x-admin-secret": []string{adminSecret},
	}
	// Propagate the active span's W3C traceparent/tracestate into the NATS
	// headers so the consumer can extract and continue the trace.
	otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(hdr))
	// Nats-Trace-Dest: when set, the NATS 2.11+ server appends a trace event to
	// the named subject at every hop (origin → route → account). The trace
	// subject includes the target action so consumers can filter by service.
	// The header is transparent to consumers — stripped before message delivery.
	if natsTraceSampleRate > 0 && rand.Float64() < natsTraceSampleRate {
		hdr["Nats-Trace-Dest"] = []string{traceDestSubject + "." + subject}
	}

	reply, err := c.nc.RequestMsgWithContext(waitCtx, &nats.Msg{
		Subject: subject,
		Data:    body,
		Header:  hdr,
	})
	if err != nil {
		if errors.Is(err, nats.ErrNoResponders) {
			m.rpcPublishErrors.Inc()
			span.SetStatus(codes.Error, "no responders")
			return rpcResponse{}, errServiceUnavailable
		}
		m.rpcPublishErrors.Inc()
		span.SetStatus(codes.Error, err.Error())
		return rpcResponse{}, fmt.Errorf("nats request: %w", err)
	}

	var resp rpcResponse
	if err := json.Unmarshal(reply.Data, &resp); err != nil {
		m.rpcPublishErrors.Inc()
		span.SetStatus(codes.Error, "unmarshal reply: "+err.Error())
		return rpcResponse{}, fmt.Errorf("unmarshal reply: %w", err)
	}

	elapsed := time.Since(started).Seconds()
	m.rpcRoundtrip.WithLabelValues(subject).Observe(elapsed)
	m.rpcRequests.WithLabelValues(subject, strconv.Itoa(resp.Status)).Inc()
	span.SetAttributes(attribute.Float64("rpc.duration_ms", elapsed*1000))
	return resp, nil
}

// run blocks until ctx is cancelled, allowing the errgroup goroutine in main to track the RPC client lifetime.
func (c *rpcClient) run(ctx context.Context, _ *metrics) {
	<-ctx.Done()
}

// Close drains the NATS connection — flushes pending outbound and unsubscribes.
func (c *rpcClient) Close() {
	_ = c.nc.Drain()
}

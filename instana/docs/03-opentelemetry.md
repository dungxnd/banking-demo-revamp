# OpenTelemetry — Instana Agent OTLP Ingestion

> **Source:** https://www.ibm.com/docs/en/instana-observability/current?topic=opentelemetry
> https://www.ibm.com/docs/en/instana-observability/current?topic=instana-agent (Sending OTel to agent)
> Condensed for: banking-demo Go microservices sending OTLP → Instana agent on EC2

---

## How OTel Fits into banking-demo

```
Go service (api-producer / auth / account / transfer / notification)
  └─ go.opentelemetry.io/otel SDK
       └─ OTLP/gRPC exporter → http://<NODE_IP>:4317
                                        │
                              Instana host agent (EC2)
                                        │
                              Instana backend (SaaS)
```

Every service calls [`internal/tracing.Init()`](../../internal/tracing/tracing.go) at startup:

- Configures an `otlptracegrpc` exporter pointing at `OTEL_EXPORTER_OTLP_ENDPOINT`
- Registers a `TracerProvider` with a batch exporter and W3C `TraceContext` propagator
- Returns a shutdown function that flushes buffered spans within 5 s on `SIGTERM`
- When `OTEL_EXPORTER_OTLP_ENDPOINT` is empty, installs a no-op propagator and skips export silently

The `api-producer` additionally wraps the Chi router with `otelhttp.NewHandler` so every HTTP
request automatically generates an OTel span — no per-handler instrumentation needed.

---

## Instana Agent OTLP Config

The agent accepts OTLP by default (agent ≥ 1.1.726). Explicit config in [`instana/configuration.yaml`](../configuration.yaml):

```yaml
com.instana.plugin.opentelemetry:
  grpc:
    enabled: true
    port: 4317
  http:
    enabled: true
    port: 4318
```

### Ports

| Protocol | Port | Default |
|----------|------|---------|
| OTLP/gRPC | 4317 | enabled |
| OTLP/HTTP | 4318 | enabled |

> **Important:** The agent listens on `0.0.0.0` by default. Pods reach it via the node IP (`status.hostIP`), not `localhost`.

---

## Pod Environment Variables

Set in each Deployment template (e.g. [`helm/templates/auth-service.yaml`](../../helm/templates/auth-service.yaml)):

```yaml
env:
  - name: NODE_IP
    valueFrom:
      fieldRef:
        fieldPath: status.hostIP
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://$(NODE_IP):4317"
  - name: OTEL_SERVICE_NAME
    value: auth-service
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "service.namespace=banking-demo"
```

`internal/tracing.Init()` reads `OTEL_EXPORTER_OTLP_ENDPOINT` directly — no `OTEL_SERVICE_NAME`
environment variable is forwarded to the SDK; the service name is hardcoded as the `serviceName`
constant in each service's `main.go` and embedded in the OTel `resource.Resource`.

The `$(NODE_IP)` substitution is performed by the Kubernetes kubelet when the pod is created —
it resolves to the EC2 host IP. The OTLP exporter then connects to that IP on port 4317 where
the host agent is listening.

---

## Go OTel Instrumentation

### Tracing library

All services use [`internal/tracing`](../../internal/tracing/tracing.go) — a thin wrapper around
`go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc`:

```go
// In each service's main.go (e.g. auth-service)
shutdownTracing := tracing.Init(serviceName, cfg.OTLPEndpoint, logger)
defer shutdownTracing(context.Background())
```

### HTTP instrumentation (api-producer)

The `api-producer` wraps its Chi router with `otelhttp.NewHandler` from
`go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp`:

```go
server := &http.Server{
    Handler: otelhttp.NewHandler(router, serviceName),
    ...
}
```

This generates a span per HTTP request with:
- `http.method`, `http.route`, `http.status_code` attributes
- W3C `traceparent`/`tracestate` header extraction from inbound requests (from Traefik)
- Span propagation to downstream NATS RPC calls via context

### NATS span propagation

W3C `traceparent` is now propagated end-to-end across the NATS boundary:

- **Producer** ([`producer/rpc.go`](../../producer/rpc.go)) — injects `traceparent` into NATS
  message headers via `otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(hdr))`
  after creating the `rpc.request` span.
- **Consumer** ([`internal/nats/consumer.go`](../../internal/nats/consumer.go)) — extracts the
  propagated span context in `dispatch` via `otel.GetTextMapPropagator().Extract(ctx, ...)` before
  calling the handler, continuing the trace as a child span.

The `propagation.TraceContext{}` propagator is registered globally by
[`internal/tracing.Init()`](../../internal/tracing/tracing.go) at every service startup.
Instana maps `messaging.system=nats` / `messaging.destination.name=<subject>` semantic conventions
to its service dependency graph — same arrows and latency charts as a native sensor.

### What appears in traces

| Span source | Span attributes | Where |
|-------------|----------------|-------|
| Traefik (ingress) | `http.method`, `http.route`, `http.url`, `http.status_code` | OTLP → agent :4317 |
| api-producer HTTP handler | `http.method`, `http.route`, `http.status_code` | OTLP → agent :4317 |
| NATS RPC request span | `messaging.system=nats`, `messaging.destination.name`, `rpc.duration_ms` | OTLP → agent :4317 |
| NATS RPC roundtrip duration | via `rpc_roundtrip_seconds` Prometheus histogram | Prometheus only |
| PostgreSQL queries | via `pg_stat_statements` (agent sensor) | Agent DB polling |
| Redis commands | via Redis sensor INFO | Agent sensor polling |

---

## Trace Headers Propagated

Config in [`instana/configuration.yaml`](../configuration.yaml):

```yaml
com.instana.tracing:
  extra-http-headers:
    - traceparent     # W3C Trace Context
    - tracestate
    - x-instana-t    # Instana native
    - x-instana-s
    - x-instana-l
```

Traefik injects `traceparent`/`tracestate` on inbound requests (via OTLP tracing configured in
the `HelmChartConfig` — `--tracing.instana` was removed in Traefik v3). The `api-producer`
extracts these headers via `otelhttp.NewHandler` and propagates the trace context downstream.

---

## OTel Signals Supported

| Signal | Status |
|--------|--------|
| Traces (OTLP/gRPC, OTLP/HTTP) | GA |
| Metrics (OTLP) | GA |
| Logs (OTLP) | GA |

Instana correlates OTel spans with its own AutoTrace spans. Mixed tracing (some hops instrumented
with OTel, others with Instana tracer) is supported.

---

## Go Collector vs OTel SDK — Two Approaches

IBM Instana provides two distinct Go instrumentation paths. banking-demo uses only the second:

| | Instana Go Collector (`go-sensor`) | OTel SDK (`go.opentelemetry.io/otel`) |
|---|---|---|
| Package | `github.com/instana/go-sensor` | `go.opentelemetry.io/otel` + exporter |
| Protocol | Instana native, port **42699** | OTLP/gRPC port **4317** |
| Transport | Direct to agent (no OTLP) | OTLP → agent or OTel Collector |
| Go runtime metrics | ✔ Free: GC pause, goroutines, heap, CPU | ✘ (use Prometheus `process_*` metrics) |
| AutoProfile™ | ✔ Continuous CPU/memory profiling | ✘ |
| W3C TraceContext | ✔ Propagates | ✔ Propagates |
| NATS tracing | ✘ Not supported in Go | ✔ W3C header propagation (producer inject + consumer extract) |
| Used by banking-demo | ✘ | ✔ (via `internal/tracing`) |

### Why banking-demo chose the OTel SDK

The OTel SDK is vendor-neutral — the same instrumentation works with Instana, Jaeger,
or any OTLP backend. `internal/tracing.Init()` is 40 lines and switches backends by
changing `OTEL_EXPORTER_OTLP_ENDPOINT`. The Go Collector requires `instana.InitSensor()`
and returns Instana-specific span types.

### Adding Go runtime metrics (optional)

To get free Go runtime metrics (goroutine count, GC pauses, heap) in Instana without
switching to the Go Collector, expose them via Prometheus and scrape with the agent:

```go
import "github.com/prometheus/client_golang/prometheus/promhttp"

// In main.go — expose /metrics on a sidecar port (e.g. :9090)
http.Handle("/metrics", promhttp.Handler())
```

The agent picks up `process_*` and `go_*` Prometheus metrics automatically if the
process exposes a Prometheus endpoint.

---

## OTel Collector (Optional — not used by default)

The `monitoring/` directory ships an OTel Collector that can be deployed as an alternative or
addition to sending spans directly to the Instana agent:

```bash
# Deploy self-hosted monitoring stack (Prometheus + Grafana + Jaeger + OTel Collector)
kubectl apply -f monitoring/

# Point services at the OTel Collector instead of the Instana agent
helm upgrade banking-demo ./helm -n banking --reuse-values \
  --set 'global.env.OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.monitoring.svc.cluster.local:4317'
```

For Instana-only deployments, services export directly to the agent — no collector needed.

To switch back to the Instana agent:

```bash
helm upgrade banking-demo ./helm -n banking --reuse-values \
  --set 'global.env.OTEL_EXPORTER_OTLP_ENDPOINT=http://instana-agent.instana-agent.svc.cluster.local:4317'
```

---

## Verifying Traces in Instana UI

1. **Instana UI → Services** — each banking service appears after first traces
2. **Instana UI → Analytics → Calls** — filter by `service.name = api-producer` to see spans
3. **Instana UI → Infrastructure → EC2 node** — shows OTel metrics from services

### Troubleshooting

```bash
# Check agent is listening on OTLP ports
sudo ss -tlnp | grep -E '4317|4318'

# Check agent accepted spans
sudo grep -i "opentelemetry\|otlp" /opt/instana/agent/log/agent.log | tail -20

# Verify pod has the OTLP endpoint set correctly
kubectl -n banking exec deploy/auth-service -- env | grep -E 'NODE_IP|OTEL'
# Expected:
# NODE_IP=10.0.x.x
# OTEL_EXPORTER_OTLP_ENDPOINT=http://10.0.x.x:4317
# OTEL_SERVICE_NAME=auth-service
# OTEL_RESOURCE_ATTRIBUTES=service.namespace=banking-demo
```

# AMQP → NATS Migration Plan

**banking-demo** · RabbitMQ (`amqp091-go v1.12.0`) → NATS (`nats.go v1.52.0`) · 6 phases

---

## Current Architecture (AMQP)

The `api-producer` acts as an HTTP gateway. Every HTTP request is forwarded as an RPC call over RabbitMQ using the *per-request exclusive callback queue* pattern:

1. Producer dials `RABBITMQ_URL`, opens a **publish channel** (with confirms) and a shared **reply channel**.
2. A single exclusive auto-delete reply queue is declared once per producer instance on connect.
3. Each request is published to a named durable queue (`auth.requests`, `account.requests`, `transfer.requests`, `notification.requests`) with a `CorrelationId` and `ReplyTo` header.
4. Consumer services subscribe to their respective durable queue, dispatch to a handler, then `ch.Publish(replyTo, correlationID, resp)`.
5. Producer matches reply by `correlationID` in a `sync.Map` of pending futures.
6. `transfer-service` additionally does a **fire-and-forget Redis PUBLISH** to `notify:<userID>` after a successful commit, which `notification-service`'s WebSocket handler consumes via Redis pub/sub.

**Key files affected:**

| File | Role |
|---|---|
| [`producer/rpc.go`](../producer/rpc.go) | AMQP client — connection lifecycle, publish confirms, reply queue, pending map |
| [`producer/metrics.go`](../producer/metrics.go) | Prometheus metrics — includes `rabbitmq_connected` gauge and `rpc_publish_errors_total` |
| [`producer/handlers.go`](../producer/handlers.go) | `healthHandler` checks `client.ready` flag; `pathToQueue` maps URL prefix → queue name |
| [`internal/amqp/consumer.go`](../internal/amqp/consumer.go) | Shared RPC consumer framework used by all 4 services |
| [`internal/health/health.go`](../internal/health/health.go) | `AMQPHandler` — typed as `amqpinternal.Handler`; imports `banking-demo/internal/amqp` directly |
| [`internal/service/service.go`](../internal/service/service.go) | `Runner` field is `*internlamqp.Consumer` — concrete type, not an interface |
| [`services/*/main.go`](../services) | Per-service wiring (×4) — all import `internlamqp "banking-demo/internal/amqp"` |
| [`services/transfer-service/handlers.go`](../services/transfer-service/handlers.go) | Handler function signature uses `internlamqp.Handler`; calls `internlamqp.Reply()` and `internlamqp.UserIDFromContext()` |
| [`services/notification-service/ws.go`](../services/notification-service/ws.go) | WebSocket fan-out reads from Redis pub/sub — no AMQP dependency, unchanged |
| [`internal/metrics/metrics.go`](../internal/metrics/metrics.go) | `ConsumerMetrics` — three Prometheus metric names are AMQP-prefixed |
| [`docker-compose.yml`](../docker-compose.yml) | `rabbitmq` service block; `RABBITMQ_URL` env var on every container |
| [`internal/go.mod`](../internal/go.mod) | `github.com/rabbitmq/amqp091-go` dependency |
| [`producer/go.mod`](../producer/go.mod) | `github.com/rabbitmq/amqp091-go` + `github.com/google/uuid` |

---

## NATS vs RabbitMQ Feature Comparison

| Dimension | NATS (with JetStream) | RabbitMQ |
|---|---|---|
| Design philosophy | Simple, fast, lightweight | Feature-rich, reliable, enterprise-grade |
| Throughput | Very high (~92,300 msg/s, up to 220K+) | Moderate (~18,200 msg/s) |
| Latency | Microsecond to millisecond | Millisecond |
| Deployment & ops | Minimal: single binary, no external dependencies | Complex: requires Erlang runtime, extensive config |
| Go ecosystem fit | Native-friendly; `nats.go` officially maintained, seamless Go integration | Mature but dated; `amqp091-go` API design is older |
| Message model | Subject-based pub/sub, request/reply, queue groups | Exchange + Queue + Binding — complex routing |
| Persistence & replay | Via JetStream: durable streams, history replay | Supported, but history replay weaker than NATS |
| Delivery semantics | Core NATS: at-most-once; JetStream: at-least-once and stronger | Configurable, supports at-least-once |

---

## AMQP → NATS Concept Mapping

| AMQP / RabbitMQ | NATS Equivalent | Notes |
|---|---|---|
| Named durable queue (`auth.requests`) | Subject (`auth.requests`) | Subjects are implicit — no declaration needed |
| `QueueDeclare` + `Consume` | `nc.QueueSubscribe(subject, group, handler)` | Queue group = load-balanced fanout, identical semantics |
| Exclusive auto-delete reply queue | Built-in inbox (`_INBOX.<random>`) | Managed by `nc.RequestMsgWithContext()` — no declaration needed |
| `ch.PublishWithContext` + `NotifyPublish` (confirm) | `nc.RequestMsgWithContext()` | Single blocking call; reply = proof of delivery |
| `delivery.CorrelationId` + `ReplyTo` header | `msg.Reply` (built-in on every message) | No manual correlation ID needed |
| `delivery.Ack` / `Nack` | *(none — Core NATS)* | At-most-once; no acks in RPC reply pattern |
| `ch.Qos(prefetch)` | `sub.SetPendingLimits(msgs, bytes)` | Controls in-memory buffer per subscription |
| Manual reconnect loop in `run()` | Built-in auto-reconnect | `nats.MaxReconnects(-1)` + `nats.ReconnectWait(2s)` |
| Publisher confirms (broker durability) | Not needed for RPC | Receiving a reply is a stronger delivery proof |
| `RABBITMQ_URL` env var | `NATS_URL` env var | Default: `nats://nats:4222` |
| `rabbitmq:4-management-alpine` container | `nats:latest` container | Port 4222 (client), 8222 (HTTP monitoring) |
| `rabbitmq_connected` Prometheus gauge | `nats_connected` Prometheus gauge | Renamed in `producer/metrics.go` |

---

## Key Behaviour Differences

| Topic | AMQP (current) | NATS (new) |
|---|---|---|
| Delivery guarantee | At-least-once (acks + durable queues) | At-most-once (Core NATS). Acceptable for RPC — the reply proves delivery. |
| Message persistence across restart | Yes (durable queues) | No. Acceptable because HTTP callers retry on timeout. |
| Publisher confirms | Yes — code waits for broker ack | Not applicable — `nc.Request()` receiving a reply is a stronger guarantee. |
| Prefetch / backpressure | `ch.Qos(5)` | `sub.SetPendingLimits(64, 1MB)` — slow consumer detection built-in. |
| No service available | Request sits in durable queue until consumer reconnects | `nats.ErrNoResponders` returned immediately → HTTP 503. |
| Broker resource usage | RabbitMQ: ~200 MB RAM, Erlang runtime | NATS server: ~10 MB RAM, single static binary. |
| `ready` flag on producer | `client.ready atomic.Bool` — set false on disconnect | `nc.Status() == nats.CONNECTED` — checked in health handler. |

---

## Migration Phases

### Phase 1 — Dependency swap ✅ implemented

Replace `github.com/rabbitmq/amqp091-go` with `github.com/nats-io/nats.go v1.52.0` in both Go modules.

**Files:** [`internal/go.mod`](../internal/go.mod), [`producer/go.mod`](../producer/go.mod)

```bash
# Run in both internal/ and producer/
go get github.com/nats-io/nats.go@v1.52.0
go mod tidy
```

- Remove: `github.com/rabbitmq/amqp091-go`
- Add: `github.com/nats-io/nats.go v1.52.0`
- `github.com/google/uuid` in `producer/go.mod`: moved from direct → indirect (still present as a transitive dep of nats.go; `go mod tidy` handles this automatically — do not manually remove it)

---

### Phase 2 — Rewrite `internal/amqp/consumer.go` → `internal/nats/consumer.go` ✅ implemented

This is the largest single change. The **public API is preserved unchanged** — all 4 service `handlers.go` files call `internlamqp.Handler`, `internlamqp.Reply()`, `internlamqp.UserIDFromContext()`, `RequireSession`, `RequireAdmin` — renaming these would require touching every handler. Instead, keep the same exported names and types; only the import alias changes in service `main.go`.

**File:** [`internal/amqp/consumer.go`](../internal/amqp/consumer.go) → new package `internal/nats/consumer.go`

#### Struct changes

| Field (AMQP `Consumer`) | Field (NATS `Consumer`) |
|---|---|
| `url string` | `url string` (same) |
| `queue string` | `subject string` + `group string` (group defaults to subject name) |
| `prefetch int` | `pendingMsgs int` (used in `sub.SetPendingLimits`) |
| `reconnectDelay time.Duration` | Removed — nats.go handles reconnect internally |
| outer `Run()` reconnect loop (50 lines) | Removed — nats.go is self-healing |
| `metrics.ReconnectsTotal` incremented in loop | Incremented in `nats.ReconnectHandler` callback |

#### Core implementation diff

```go
// BEFORE (AMQP) — internal/amqp/consumer.go
func (c *Consumer) Run(ctx context.Context) {
    first := true
    for {
        if err := c.run(ctx); err != nil {
            c.logger.Error("amqp_consumer_error", "error", err)
            if !first && c.metrics != nil { c.metrics.ReconnectsTotal.Inc() }
            first = false
            select {
            case <-ctx.Done(): return
            case <-time.After(c.reconnectDelay):
            }
        }
    }
}

func (c *Consumer) run(ctx context.Context) error {
    conn, _ := amqp.DialConfig(c.url, amqp.Config{
        Dial: func(network, addr string) (net.Conn, error) {
            return (&net.Dialer{Timeout: 30*time.Second}).DialContext(ctx, network, addr)
        },
    })
    defer conn.Close()
    ch, _ := conn.Channel()
    ch.Qos(c.prefetch, 0, false)
    ch.QueueDeclare(c.queue, true, false, false, false, nil)
    deliveries, _ := ch.Consume(c.queue, "", false, false, false, false, nil)
    closeCh := make(chan *amqp.Error, 1)
    conn.NotifyClose(closeCh)
    for {
        select {
        case <-ctx.Done():            return nil
        case amqpErr := <-closeCh:   return fmt.Errorf("connection closed: %w", amqpErr)
        case delivery := <-deliveries:
            go c.dispatch(ctx, ch, delivery)
        }
    }
}

func (c *Consumer) dispatch(ctx context.Context, ch *amqp.Channel, d amqp.Delivery) {
    if ctx.Err() != nil { d.Nack(false, true); return }  // requeue on shutdown
    json.Unmarshal(d.Body, &req)
    // headers read from req.Headers (embedded in JSON body)
    result, _ := handler(ctx, req.Action, req.Payload, req.Headers)
    replyBody, _ := json.Marshal(resp)
    ch.Publish("", d.ReplyTo, false, false, amqp.Publishing{
        CorrelationId: d.CorrelationId,
        Body:          replyBody,
    })
    d.Ack(false)
}
```

```go
// AFTER (NATS) — internal/nats/consumer.go
func (c *Consumer) Run(ctx context.Context) {
    nc, err := nats.Connect(c.url,
        nats.Name(c.subject),                  // identifies consumer in server logs/monitoring
        nats.MaxReconnects(-1),
        nats.ReconnectWait(2*time.Second),
        nats.ReconnectJitter(500*time.Millisecond, 2*time.Second), // prevent thundering herd on mass restart
        nats.RetryOnFailedConnect(true),        // survive startup races — no depends_on ordering needed
        nats.PingInterval(20*time.Second),      // detect silent network partitions within ~100s
        nats.MaxPingsOutstanding(5),
        nats.ReconnectHandler(func(nc *nats.Conn) {
            if c.metrics != nil { c.metrics.ReconnectsTotal.Inc() }
            c.logger.Info("nats_reconnected", "url", nc.ConnectedUrl())
        }),
        nats.DisconnectErrHandler(func(_ *nats.Conn, err error) {
            c.logger.Error("nats_disconnected", "error", err)
        }),
        // ErrSlowConsumer fires locally before the server disconnects the client.
        nats.ErrorHandler(func(_ *nats.Conn, sub *nats.Subscription, natErr error) {
            if errors.Is(natErr, nats.ErrSlowConsumer) {
                dropped, _ := sub.Dropped()
                c.logger.Error("nats_slow_consumer",
                    "subject", sub.Subject, "dropped", dropped)
            }
        }),
    )
    if err != nil {
        // RetryOnFailedConnect=true means this only fires if MaxReconnects is exhausted
        // (which never happens with -1). Log and let Run() return to exit the service.
        c.logger.Error("nats_connect_failed", "error", err)
        return
    }
    defer nc.Drain()

    sub, _ := nc.QueueSubscribe(c.subject, c.group, func(msg *nats.Msg) {
        go c.dispatch(ctx, msg)
    })
    // Default pending limits: 65536 msgs / 64MB bytes — explicit here for visibility.
    // Lower these to detect slow-consumer problems earlier in staging.
    sub.SetPendingLimits(c.pendingMsgs, c.pendingMsgs*4096)
    c.logger.Info("nats_consumer_started", "subject", c.subject, "group", c.group)

    <-ctx.Done()
    // sub.Drain waits for all in-flight dispatch goroutines to complete before
    // unsubscribing. Pass a detached context — the parent is already cancelled
    // here, and sub.Drain creates its own internal deadline.
    if err := sub.Drain(); err != nil {
        c.logger.Error("nats_drain_failed", "error", err)
    }
}

func (c *Consumer) dispatch(ctx context.Context, msg *nats.Msg) {
    if ctx.Err() != nil { return } // drop on shutdown — no requeue in Core NATS
    var req rpcRequest
    json.Unmarshal(msg.Data, &req)
    // Headers forwarded via NATS message headers (not embedded in JSON body)
    headers := map[string]string{
        "x-session":      msg.Header.Get("x-session"),
        "x-admin-secret": msg.Header.Get("x-admin-secret"),
    }
    result, _ := handler(ctx, req.Action, req.Payload, headers)
    replyBody, _ := json.Marshal(resp)
    msg.Respond(replyBody) // built-in — reply subject + correlation managed by nats.go
}
```

#### Graceful shutdown note

`sub.Drain()` waits for all in-flight message handler goroutines to complete before unsubscribing. `nc.Drain()` (deferred) then flushes all pending outbound. This replaces the `Nack(false, true)` requeue guard in the current AMQP `dispatch`. In Core NATS, messages in-flight at shutdown are simply completed; there is no requeue — which is safe because the producer's request will time out and return an error to the HTTP caller if the response is not received.

#### `rpcRequest` struct — header field change

The current AMQP consumer reads `x-session` and `x-admin-secret` from the **JSON body** (`req.Headers` field). The NATS version reads them from **NATS message headers** (`msg.Header.Get(...)`). Both the consumer and the producer must be consistent on which mechanism is used. The plan uses NATS headers (the correct approach). The `rpcRequest.Headers` field in the JSON body can be removed or left unused for backwards compatibility during transition.

---

### Phase 3 — Rewrite `producer/rpc.go` and `producer/metrics.go` ✅ implemented

The AMQP `rpcClient` manages two channels, a reply queue, a confirm cycle, and a correlation map manually (~250 lines). NATS replaces the entire transport with `nc.RequestMsgWithContext()`.

**Files:** [`producer/rpc.go`](../producer/rpc.go), [`producer/metrics.go`](../producer/metrics.go)

#### What gets removed from `rpc.go`

- `pubCh *amqp.Channel`, `replyCh *amqp.Channel`, `replyQueue string`
- `publishMu sync.Mutex` — serialized confirm cycle
- `pending sync.Map` — manual correlation map
- `consumeReplies()` goroutine
- `reset()` — drain pending on disconnect with 502
- `connect()` function (~55 lines)
- `run()` reconnect loop (~35 lines)
- `ready atomic.Bool`, `closed atomic.Bool`, `closeOnce sync.Once`
- `errPublishNotConfirmed` sentinel error

#### New `rpc.go` implementation

```go
type rpcClient struct {
    nc              *nats.Conn
    logger          *slog.Logger
    tracer          trace.Tracer
    responseTimeout time.Duration
}

func newRPCClient(cfg config, logger *slog.Logger) *rpcClient {
    nc, err := nats.Connect(cfg.NATSURL,
        nats.Name(serviceName),                // visible in NATS server monitoring (/connz)
        nats.MaxReconnects(-1),                // never give up — producer must stay alive
        nats.ReconnectWait(2*time.Second),
        nats.ReconnectJitter(500*time.Millisecond, 2*time.Second), // jitter prevents thundering herd
        nats.RetryOnFailedConnect(true),       // survive container startup races; don't fail-fast
        nats.PingInterval(20*time.Second),     // detect silent TCP hangs; dead conn closed in ~100s
        nats.MaxPingsOutstanding(5),
        nats.ReconnectBufSize(8*1024*1024),    // 8MB publish buffer during disconnect (default, explicit)
        nats.DisconnectErrHandler(func(_ *nats.Conn, err error) {
            logger.Error("nats_disconnected", "error", err)
        }),
        nats.ReconnectHandler(func(nc *nats.Conn) {
            logger.Info("nats_reconnected", "url", nc.ConnectedUrl())
        }),
        nats.ClosedHandler(func(_ *nats.Conn) {
            // Only fires if MaxReconnects exhausted — never with -1
            logger.Error("nats_connection_permanently_closed")
        }),
    )
    if err != nil {
        // RetryOnFailedConnect=true: nats.Connect returns only after MaxReconnects exhausted.
        // With -1 this never happens — so this path is unreachable in practice.
        logger.Error("nats_connect_fatal", "error", err.Error())
        os.Exit(1)
    }
    return &rpcClient{nc: nc, logger: logger,
        tracer: otel.Tracer(serviceName), responseTimeout: cfg.ResponseTimeout}
}

// call publishes req to subject and blocks until a reply arrives or the context expires.
// Returns errServiceUnavailable (→ HTTP 503) when no consumers are subscribed.
func (c *rpcClient) call(ctx context.Context, subject string,
    req rpcRequest, m *metrics) (rpcResponse, error) {

    // Fast-path: if the HTTP request was already cancelled, skip the work.
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

    reply, err := c.nc.RequestMsgWithContext(waitCtx, &nats.Msg{
        Subject: subject,
        Data:    body,
        Header: nats.Header{
            "x-session":      []string{req.Headers["x-session"]},
            "x-admin-secret": []string{req.Headers["x-admin-secret"]},
        },
    })
    if err != nil {
        if errors.Is(err, nats.ErrNoResponders) {
            m.rpcPublishErrors.Inc()
            span.SetStatus(codes.Error, "no responders")
            return rpcResponse{}, errServiceUnavailable // → HTTP 503
        }
        m.rpcPublishErrors.Inc()
        span.SetStatus(codes.Error, err.Error())
        return rpcResponse{}, fmt.Errorf("nats request: %w", err)
    }

    var resp rpcResponse
    if err := json.Unmarshal(reply.Data, &resp); err != nil {
        // Marshal on a known-safe struct; if it fails treat as a publish error.
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

// run blocks until ctx is cancelled. nats.go reconnects automatically;
// this exists so main.go's errgroup goroutine has something to wait on.
func (c *rpcClient) run(ctx context.Context, _ *metrics) { <-ctx.Done() }

func (c *rpcClient) Close() { _ = c.nc.Drain() }
```

#### Changes to `producer/handlers.go`

Three items in `handlers.go` need updating: the `ready` flag check, the `pathToQueue` subject names, and the `call()` return signature.

**1. `pathToQueue` — adopt subject hierarchy (from NATS docs: *"Use the first token(s) to establish a general namespace"*)**

```go
// Before — flat subjects
func pathToQueue(path string) string {
    switch {
    case strings.HasPrefix(path, "/api/auth"):          return "auth.requests"
    case strings.HasPrefix(path, "/api/account"):       return "account.requests"
    case strings.HasPrefix(path, "/api/transfer"):      return "transfer.requests"
    case strings.HasPrefix(path, "/api/notifications"): return "notification.requests"
    default:                                            return ""
    }
}

// After — three-token hierarchy enables wildcard monitoring and security ACLs.
// Subscribe `banking.>` to wire-tap all RPC traffic; `banking.*.requests` for a
// single Prometheus subscription across all services.
// NOTE: This is the Phase 3 intermediate naming. Two future evolutions exist:
//   - CQRS Tier 1a: service-level split → `.commands` / `.queries` per subject
//   - Phase 6b (recommended): action-level subjects → `banking.auth.login` etc.
// Phase 6b supersedes Tier 1a; if Phase 6 is planned, skip Tier 1a.
func pathToQueue(path string) string {
    switch {
    case strings.HasPrefix(path, "/api/auth"):          return "banking.auth.requests"
    case strings.HasPrefix(path, "/api/account"):       return "banking.account.requests"
    case strings.HasPrefix(path, "/api/transfer"):      return "banking.transfer.requests"
    case strings.HasPrefix(path, "/api/notifications"): return "banking.notification.requests"
    default:                                            return ""
    }
}
```

**2. `healthHandler` — fix `ready` flag and rename broker key**

```go
// healthHandler — Before
payload := map[string]any{
    "status":   "healthy",
    "rabbitmq": "ok",
}
if !client.ready.Load() {    // ready atomic.Bool no longer exists
    payload["rabbitmq"] = "closed"
}

// healthHandler — After
payload := map[string]any{
    "status": "healthy",
    "nats":   "ok",
}
if c.nc.Status() != nats.CONNECTED {
    status = http.StatusServiceUnavailable
    payload["status"] = "unhealthy"
    payload["nats"] = "disconnected"
}
```

**3. `call()` return signature — remove `correlationID`**

Also the `call()` return signature changes from `(rpcResponse, string, error)` (current — returns `correlationID`) to `(rpcResponse, error)`. Update the two call sites in `proxyHandler` accordingly:

```go
// Before
resp, correlationID, err := client.call(r.Context(), queue, req, m)
if correlationID != "" {
    w.Header().Set("X-Correlation-Id", correlationID)
}

// After — NATS manages correlation internally; remove the header
resp, err := client.call(r.Context(), queue, req, m)
// Remove the X-Correlation-Id response header line entirely
```

#### Changes to `producer/metrics.go`

```go
// Before
rabbitmqConnected prometheus.Gauge  // field name
Name: "rabbitmq_connected"          // metric name

// After
natsConnected prometheus.Gauge
Name: "nats_connected"
Help: "Whether the NATS connection is active (1) or not (0)."
```

The `rpcPublishErrors` counter was previously incremented on failed AMQP confirms. With NATS it fires on `ErrNoResponders` and other publish errors — semantics are identical, name stays the same.

Remove `rpcReplyErrors` counter — `consumeReplies()` goroutine that used it is deleted. The metric name can be retired or reused for unmarshal errors.

#### Config field rename in `producer/main.go`

```go
// Before
RabbitMQURL     string        `env:"RABBITMQ_URL"              envDefault:"amqp://guest:guest@rabbitmq:5672/"`

// After
NATSURL         string        `env:"NATS_URL"                  envDefault:"nats://nats:4222"`
```

---

### Phase 4 — Update wiring (all 4 services + shared packages) ✅ implemented

#### 4a. `internal/service/service.go`

The `Runner` struct holds a **concrete** `*internlamqp.Consumer` field — this must change to the new type:

```go
// Before
import internlamqp "banking-demo/internal/amqp"
type Runner struct {
    consumer *internlamqp.Consumer
    ...
}
func NewRunner(consumer *internlamqp.Consumer, ...) *Runner

// After
import internnats "banking-demo/internal/nats"
type Runner struct {
    consumer *internnats.Consumer
    ...
}
func NewRunner(consumer *internnats.Consumer, ...) *Runner
```

#### 4b. Each service `main.go` (×4)

Applies identically to [`services/auth-service/main.go`](../services/auth-service/main.go), [`services/account-service/main.go`](../services/account-service/main.go), [`services/transfer-service/main.go`](../services/transfer-service/main.go), [`services/notification-service/main.go`](../services/notification-service/main.go).

Update both the import alias, the config env field, **and the queue name constants** (must match Phase 3's `pathToQueue` subjects):

```go
// Before
import internlamqp "banking-demo/internal/amqp"
const authQueue = "auth.requests"
RabbitMQURL string `env:"RABBITMQ_URL" envDefault:"amqp://guest:guest@rabbitmq:5672/"`
consumer := internlamqp.NewConsumer(cfg.RabbitMQURL, authQueue, logger, …)

// After
import internnats "banking-demo/internal/nats"
const authQueue = "banking.auth.requests"   // must match pathToQueue in producer/handlers.go
NATSURL string `env:"NATS_URL" envDefault:"nats://nats:4222"`
consumer := internnats.NewConsumer(cfg.NATSURL, authQueue, logger, …)
```

The queue name constants in each service, with the two possible evolution paths:

| Service | Phase 3/4 subject (RPC) | CQRS Tier 1a split | Phase 6b action subjects |
|---|---|---|---|
| auth-service | `banking.auth.requests` | `.commands` + `.queries` | `banking.auth.login`, `banking.auth.register` |
| account-service | `banking.account.requests` | `.queries` | `banking.account.balance`, `banking.account.me`, … |
| transfer-service | `banking.transfer.requests` | `.commands` | `banking.transfer.send` |
| notification-service | `banking.notification.requests` | `.queries` | `banking.notification.list` |

> **Why the hierarchy?** NATS docs: *"Use the first token(s) to establish a general namespace."* The `banking.` prefix enables: a single `banking.>` wire-tap subscription to observe all RPC traffic; ACL rules scoped to `banking.auth.*` per service; future JetStream stream config `banking.events.>` to capture all post-commit events.
>
> **Tier 1a vs Phase 6b:** CQRS Tier 1a (service-level `.commands`/`.queries` split) and Phase 6b (per-action subjects) are **alternatives, not stackable**. Phase 6b subsumes Tier 1a — action names already encode command vs query intent. If Phase 6 is on the roadmap, skip Tier 1a and go directly to Phase 6b. See [`cqrs-plan.md`](./cqrs-plan.md) for the CQRS Tier 1b (cache fix) and Tier 2 (balance read model), which are independent of this choice.

#### 4c. All service `handlers.go` files — import alias only

Each handler file imports the amqp package for `Handler`, `Reply()`, and `UserIDFromContext()`. Since the new package `internal/nats` exports the identical types and functions, only the import alias changes:

```go
// Before (in all handlers.go files)
internlamqp "banking-demo/internal/amqp"
// usage: internlamqp.Handler, internlamqp.Reply(), internlamqp.UserIDFromContext()

// After
internnats "banking-demo/internal/nats"
// usage: internnats.Handler, internnats.Reply(), internnats.UserIDFromContext()
```

This is a **search-and-replace** across `services/*/handlers.go` and `services/*/admin.go`.

#### 4d. `internal/health/health.go`

The file imports `banking-demo/internal/amqp` for the `AMQPHandler` return type:

```go
// Before
import amqpinternal "banking-demo/internal/amqp"
func AMQPHandler(...) amqpinternal.Handler { ... }
// Uses: amqpinternal.Reply(200, ...) and amqpinternal.Reply(503, ...)

// After — rename function, fix import
import natsinternal "banking-demo/internal/nats"
func NATSHandler(...) natsinternal.Handler { ... }
// Usage of Reply() and body unchanged — only import and function name change
```

The **4 service `main.go` call sites** that register this handler also update:

```go
// Before
internlamqp.WithHandler("health", health.AMQPHandler(serviceName, d.Pool, d.RedisClient))

// After
internnats.WithHandler("health", health.NATSHandler(serviceName, d.Pool, d.RedisClient))
```

#### 4e. `internal/metrics/metrics.go`

Rename the three Prometheus metric name strings — the `ConsumerMetrics` struct shape is unchanged:

```go
// Before → After
"amqp_messages_total"           →  "nats_messages_total"
"amqp_handler_duration_seconds" →  "nats_handler_duration_seconds"
"amqp_reconnects_total"         →  "nats_reconnects_total"
```

> **Note:** Update any Grafana dashboards querying these metric names in the same PR.

---

### Phase 5 — Infrastructure (Docker Compose & Helm) ✅ implemented

#### 5a. `docker-compose.yml`

```yaml
# Remove the entire rabbitmq: service block.
# Add NATS server + nats-exporter (Prometheus scrape target):

  nats:
    image: nats:2-alpine          # pin major version; nats:latest also works
    container_name: banking-nats
    ports:
      - "4222:4222"   # client connections
      - "8222:8222"   # HTTP monitoring (/healthz /varz /connz /subsz)
    command: ["--http_port", "8222"]
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:8222/healthz"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  # prometheus-nats-exporter scrapes NATS /varz /connz /subsz and exposes
  # them as Prometheus metrics alongside the existing service metrics.
  # The nats.Name(serviceName) option added to every connection makes
  # /connz output readable — each connection shows the service name.
  nats-exporter:
    image: natsio/prometheus-nats-exporter:0.20.1  # pin version — matches docker-compose.yml
    container_name: banking-nats-exporter
    command: ["-varz", "-connz", "-subz", "http://nats:8222"]
    ports:
      - "7777:7777"   # Prometheus scrape target
    depends_on:
      - nats
    restart: unless-stopped

# In api-producer and all 4 service blocks:
# Replace:  RABBITMQ_URL: amqp://banking:bankingpass@rabbitmq:5672/
# With:     NATS_URL: nats://nats:4222

# Replace in every depends_on block:
# rabbitmq: condition: service_healthy
# →  nats: condition: service_started
# (RetryOnFailedConnect=true means services retry until NATS is ready;
#  service_started is sufficient — no need to block on service_healthy)
```

**Ops note — wire tap** (zero code, uses NATS subject hierarchy from Phase 4b):

The NATS docs describe the wire tap pattern: *"wildcards can be used for monitoring by creating something called a wire tap"*. With the `banking.*` hierarchy now in place:

```bash
# Watch ALL banking RPC traffic in real time (debugging, load tests)
nats sub "banking.>"

# Watch only transfer requests
nats sub "banking.transfer.requests"

# Benchmark auth service RPC latency (requires nats CLI)
nats bench service request banking.auth.requests --count 1000

# Check which queue group members are active
nats sub "$SYS.REQ.SERVER.PING.IDZ"  # or use: nats server ls
```

This is a free observability primitive. RabbitMQ requires the Firehose plugin for equivalent capability.

#### 5b. Helm charts (`helm/templates/*.yaml`)

```yaml
# In each *-service.yaml — replace the env var:
# Remove:
- name: RABBITMQ_URL
  value: "amqp://…"
# Add:
- name: NATS_URL
  value: "nats://nats:4222"

# Add a NATS deployment, or use the official Helm chart:
#   helm repo add nats https://nats-io.github.io/k8s/helm/charts/
#   helm install nats nats/nats
```

#### 5c. Cleanup

- Delete `internal/amqp/` directory after `internal/nats/` is verified
- Delete or replace `rabbitmq/` directory (RabbitMQ broker config)
- Replace `ARCH-RMQ-RPC.md` with `ARCH-NATS-RPC.md`

---

## JetStream: Why Not Used Here, and Where It Would Apply

### Why Core NATS is correct for the RPC transport

The RabbitMQ AMQP RPC pattern in this project is **synchronous request/reply**. The producer in [`producer/rpc.go`](../producer/rpc.go) blocks until it receives a response or times out. This means:

1. **A received reply is a stronger delivery guarantee than a broker ack.** The message was not just accepted by the broker — it was processed by a handler and a result was returned. JetStream publisher acks only confirm broker receipt, not processing.
2. **JetStream cannot serve the reply half of RPC.** Replies go to `_INBOX.*` subjects which are ephemeral Core NATS inboxes by definition. JetStream streams cannot capture `_INBOX.*`.
3. **`ErrNoResponders` is better UX than durable queuing.** If all consumers are down, Core NATS returns the error immediately → HTTP 503. With a JetStream stream, the request would be durably held and the HTTP caller would hang until the full 60s timeout.
4. **JetStream adds operational overhead** — stream declarations, consumer configs, ack policies, redelivery intervals — none of which maps to the existing synchronous RPC semantics.

### Where JetStream *would* strengthen this project (future phases)

These are real gaps in the current architecture where JetStream's at-least-once and exactly-once guarantees add genuine value:

| Use case | Current gap | JetStream solution |
|---|---|---|
| **Balance projection** — read model must survive Redis restart | `account-service` falls back to DB on cold start; no replay path | Durable **pull consumer** (`Consume()`) on `BANKING_EVENTS` stream with `DeliverAllPolicy`; replays full event log to rebuild Redis hash on restart |
| **Transfer event durability** — WebSocket event lost if `notification-service` is down | Redis `PUBLISH` is fire-and-forget after commit | Ephemeral **push consumer** per WebSocket session with `AckNonePolicy` + `DeliverNewPolicy`; or keep Redis pub/sub and use JetStream only for projection (both are valid) |
| **Audit log / replay** — replay all transfers for a given account | Not possible today — no durable event log | JetStream `BANKING_EVENTS` stream with `LimitsPolicy` retention; ephemeral ordered pull consumer with `DeliverByStartTimePolicy` for point-in-time replay |
| **Transfer idempotency** — prevent double-submit on client retry | No idempotency guard today | `Nats-Msg-Id` deduplication header on the JetStream publish; `Duplicates` window on stream config |

### JetStream publish code sketch (transfer audit log — future)

These examples use the **modern `github.com/nats-io/nats.go/jetstream` package** recommended
for new projects since nats.go v1.28+. See [`fork-docs/cqrs-plan.md`](./cqrs-plan.md) Tier 3 for
the full production implementation with Redis projection, push/pull consumer decision criteria,
and complete code including `MaxAckPending`, `BackOff`, and `DeliverAllPolicy` for read model
rebuild after Redis failure.

```go
import "github.com/nats-io/nats.go/jetstream"

js, _ := jetstream.New(nc)

// Declare the stream once at startup (idempotent)
_, err := js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
    Name:       "BANKING_EVENTS",
    Subjects:   []string{"banking.events.>"},
    Retention:  jetstream.LimitsPolicy,
    MaxAge:     30 * 24 * time.Hour,
    Storage:    jetstream.FileStorage,
    Duplicates: 5 * time.Minute,  // dedup window for Nats-Msg-Id
})

// After runTransferTx succeeds, publish with deduplication header
_, err = js.PublishMsg(ctx, &nats.Msg{
    Subject: "banking.events.transfer.completed",
    Data:    eventJSON,
    Header:  nats.Header{"Nats-Msg-Id": []string{strconv.Itoa(int(res.transferID))}},
})
```

```go
// Durable pull consumer for balance projection — Consume() for continuous delivery
cons, _ := js.CreateOrUpdateConsumer(ctx, "BANKING_EVENTS", jetstream.ConsumerConfig{
    Durable:       "account-service-balance",
    FilterSubject: "banking.events.transfer.completed",
    AckPolicy:     jetstream.AckExplicitPolicy,
    DeliverPolicy: jetstream.DeliverAllPolicy,  // replay full log after Redis wipe
    MaxAckPending: 100,
})
consCtx, _ := cons.Consume(func(msg jetstream.Msg) {
    updateRedisBalance(msg.Data())
    msg.Ack()
})
defer consCtx.Stop()
```

```go
// Ephemeral ordered pull consumer for audit replay — Fetch() for batch processing
orderedCons, _ := js.OrderedConsumer(ctx, "BANKING_EVENTS", jetstream.OrderedConsumerConfig{
    FilterSubjects: []string{"banking.events.transfer.completed"},
    DeliverPolicy:  jetstream.DeliverByStartTimePolicy,
    OptStartTime:   &startTime,
})
iter, _ := orderedCons.Messages()
for {
    msg, _ := iter.Next()
    processAuditEvent(msg.Data())
    // Ordered consumers: no ack needed; gap detection + auto-recreate on errors
}
iter.Stop()
```

### Two-tier transport summary

The subject naming evolves in stages. Two alternative paths exist after Phase 3/4; choose one:

**Path A — CQRS Tier 1a then Tier 2** (service-level command/query split, no Phase 6):
```
banking.auth.commands / banking.auth.queries
banking.account.queries
banking.transfer.commands  →  post-commit  →  banking.events.transfer.completed
banking.notification.queries

Wildcard monitoring:
    banking.*.commands     → state-mutating operations only
    banking.*.queries      → read-only operations only
    banking.events.>       → JetStream stream (CQRS Tier 3, future)
```

**Path B — Phase 6b then CQRS Tier 2** (action-level subjects, recommended if Phase 6 is planned):
```
banking.auth.login / banking.auth.register
banking.account.balance / banking.account.me / banking.account.lookup / …
banking.transfer.send      →  post-commit  →  banking.events.transfer.completed
banking.notification.list

Wildcard monitoring:
    banking.>              → wire tap: all RPC + event traffic
    banking.events.>       → JetStream stream (CQRS Tier 3, future)
    nats micro stats       → per-action request counts, error rates, latency (Phase 6a)
```

> **Path B subsumes Path A.** Per-action subjects are more granular than the service-level `.commands`/`.queries` split; action names already encode the command-vs-query distinction. The `banking.events.*` subjects for JetStream events are identical in both paths and independent of this choice.

**Current state (Phase 3/4):** all subjects are `banking.*.requests` — the intermediate naming. Both paths diverge from here. CQRS Tier 1b (cache fix) and Tier 2 (Redis balance read model) are independent of which path is chosen. See [`cqrs-plan.md`](./cqrs-plan.md) for the full implementation plan.

---

## Connection Option Reference

All connection options used in this plan are sourced directly from the NATS docs. This table explains each one and justifies its inclusion.

### Consumer connections (`internal/nats/consumer.go` and `producer/rpc.go`)

| Option | Default | Value used | Why |
|---|---|---|---|
| `nats.MaxReconnects(-1)` | 60 attempts | `-1` (infinite) | Services must never give up — banking workloads require uptime |
| `nats.ReconnectWait(2s)` | 2s | `2s` | Matches existing AMQP reconnect delay |
| `nats.ReconnectJitter(500ms, 2s)` | 100ms / 1s | 500ms / 2s | Prevents thundering herd when all 5 services restart simultaneously (docker-compose up) |
| `nats.RetryOnFailedConnect(true)` | false | `true` | **Critical for containers.** Without this, if NATS isn't ready at first dial, `nats.Connect()` returns a fatal error immediately instead of retrying. With it, startup races are handled automatically — `depends_on` can be relaxed. |
| `nats.PingInterval(20s)` | 2m | `20s` | Detects silent TCP hangs (network partition where OS doesn't close socket). Dead connection identified in 20s × 5 = 100s max. |
| `nats.MaxPingsOutstanding(5)` | — | `5` | Works with `PingInterval` — connection closed as stale after 5 unanswered pings |
| `nats.ReconnectBufSize(8MB)` | 8MB | `8MB` | Explicit — publishes queued during brief disconnect window. Only relevant if producer is publishing fire-and-forget. For `RequestMsgWithContext`, requests already in-flight will fail immediately on disconnect; this buffer covers future publishes during reconnect. |
| `nats.Name(serviceName)` | — | service/subject name | Appears in NATS server `/connz` monitoring endpoint — makes log correlation easier |
| `nats.ErrorHandler(...)` | — | slow-consumer logger | NATS docs recommend wiring this to detect `nats.ErrSlowConsumer` locally before the server disconnects the client. Logs dropped message count via `sub.Dropped()`. |
| `nats.ClosedHandler(...)` | — | error logger | Fires only if `MaxReconnects` is exhausted — unreachable with `-1`, but present for observability |

### Why `RetryOnFailedConnect` matters for this project

The current AMQP setup uses `depends_on: rabbitmq: condition: service_healthy` in docker-compose to sequence startup. With `RetryOnFailedConnect(true)`:

```yaml
# docker-compose.yml — can simplify to:
depends_on:
  nats:
    condition: service_started   # not service_healthy
```

The service will start, attempt to connect, and keep retrying until NATS is ready — no hard ordering dependency. This is also essential for Kubernetes where `initContainers` are often avoided.

### `sub.SetPendingLimits` — slow consumer protection

The NATS docs document the defaults explicitly:
- **Default pending message limit:** 65,536 messages per subscription
- **Default pending byte limit:** 65,536 × 1024 = 64 MB per subscription

If the service falls behind processing, the client drops messages (at-most-once, aligned with Core NATS semantics) and calls the `ErrorHandler` with `nats.ErrSlowConsumer`. The plan sets limits explicitly for visibility:

```go
// In NewConsumer — explicit defaults surface the knob for operators
sub.SetPendingLimits(c.pendingMsgs, c.pendingMsgs*4096)
// pendingMsgs default: 64  →  limits: 64 msgs / 256KB
// (tighter than NATS default — alerts faster in staging)
```

Lower limits in staging catch slow-consumer problems before production. Raise in production if legitimate burst traffic is expected.

---

## When to Use Core NATS vs JetStream (NATS Docs Decision Tree)

Sourced directly from the NATS official docs (*"When to use Core NATS"*):

> *"Service patterns where there is a tightly coupled request-reply — a request is made, and the application handles error cases upon timeout. **Relying on a messaging system to resend here is considered an anti-pattern.**"*

This is an exact description of the banking-demo RPC pattern. All four services are request-reply with the producer holding a 60s timeout. Using JetStream for the RPC transport leg would be the anti-pattern the NATS docs explicitly warn against.

The NATS docs also define when **JetStream is appropriate**:

| JetStream signal | Present in banking-demo? |
|---|---|
| Producers and consumers may be online at different times | ✗ — producer and consumers must both be live for HTTP to work |
| Historical replay of data required | ✓ — transfer audit log (future) |
| Last message needed for initialization | ✗ |
| Exactly-once QoS with deduplication | ✓ — transfer debit/credit (future) |
| Consumers process data at their own pace (decoupled flow) | ✗ — RPC is synchronous by design |

Only the two future audit use-cases qualify for JetStream. The RPC transport is definitively Core NATS.

---

## File Impact Summary

### Core migration (Phases 1–5)

| File | Change | Effort | Status |
|---|---|---|---|
| `internal/amqp/consumer.go` | Rewrite as `internal/nats/consumer.go` | Large | ✅ done |
| `producer/rpc.go` | Rewrite — reconnect loop + pending map + confirm cycle removed (~60% lines) | Large | ✅ done |
| `producer/handlers.go` | Fix `healthHandler`; rename `pathToQueue` subjects to `banking.*` hierarchy; update `call()` return signature | Medium | ✅ done |
| `producer/metrics.go` | Rename `rabbitmqConnected` → `natsConnected`; rename metric name string | Small | ✅ done |
| `internal/health/health.go` | Rename `AMQPHandler` → `NATSHandler`; fix import path | Small | ✅ done |
| `internal/service/service.go` | Change import path + `Runner` field type | Small | ✅ done |
| `services/*/main.go` (×4) | Rename import alias + env var field + queue name constant | Trivial ×4 | ✅ done |
| `services/*/handlers.go` (×4+) | Rename import alias only (all function names preserved) | Trivial ×4 | ✅ done |
| `internal/metrics/metrics.go` | Rename 3 metric name strings | Trivial | ✅ done |
| `internal/go.mod` | Remove amqp091-go, add nats.go | Trivial | ✅ done |
| `producer/go.mod` | Remove amqp091-go; uuid moves to indirect | Trivial | ✅ done |
| `producer/main.go` | Rename `RabbitMQURL` → `NATSURL` env field | Trivial | ✅ done |
| `docker-compose.yml` | Replace rabbitmq block; add nats + nats-exporter; update env vars + depends_on | Medium | ✅ done |
| `helm/templates/*.yaml` | Replace env vars, add nats deployment | Medium | ⬜ pending |
| `ARCH-RMQ-RPC.md` → `ARCH-NATS-RPC.md` | Replace architecture doc | Small | ✅ done |

### New files created

| File | Purpose | Status |
|---|---|---|
| `internal/nats/consumer.go` | New NATS consumer package (replaces `internal/amqp/consumer.go`) | ✅ done |
| `ARCH-NATS-RPC.md` | Replacement architecture doc | ✅ done |

### Phase 6 additions (optional, post-migration)

#### CQRS Tier 3 — JetStream event bus (see cqrs-plan.md)

| File | Change | Effort |
|---|---|---|
| `docker-compose.yml` | Add `-js` flag to NATS command | Trivial |
| `helm/values.yaml` | Add JetStream storage config to NATS subchart values | Small |
| `internal/go.mod` | Add `github.com/nats-io/nats.go/jetstream` import | Trivial |
| `services/transfer-service/main.go` | Acquire `js, _ := jetstream.New(nc)` and pass to handler | Small |
| `services/transfer-service/handlers.go` | `js.PublishMsg(…)` with `Nats-Msg-Id` post-commit | Medium |
| `services/account-service/main.go` | Start durable pull consumer via `cons.Consume()` | Medium |
| `services/notification-service/main.go` | Start ephemeral push consumer for WebSocket fan-out (optional) | Medium |

#### nats/micro service framework

| File | Change | Effort |
|---|---|---|
| `internal/nats/consumer.go` | Rewrite `QueueSubscribe` → `nats/micro` service framework | Medium |
| `services/*/main.go` (×4) | Replace `WithHandler` registration → `svc.AddEndpoint` per action | Medium |
| `internal/health/health.go` | Remove — health replaced by `$SRV.PING.<name>` built-in | Small |

---

## Risks & Mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| In-flight requests lost on NATS disconnect | Medium | `ReconnectBufSize(8MB)` buffers publishes during brief disconnect. `RequestMsgWithContext` requests already waiting fail immediately and return 502 — same as current AMQP `reset()` behaviour. |
| No durable queue — messages lost if all consumers are down simultaneously | Low | RPC pattern — return 503 via `ErrNoResponders` immediately. Better UX than silently queuing. |
| Thundering herd on mass restart (all 5 services + producer reconnecting simultaneously) | Medium | `ReconnectJitter(500ms, 2s)` adds randomized backoff — docs-recommended mitigation for this exact scenario. |
| Container startup race — service starts before NATS is ready | Low | `RetryOnFailedConnect(true)` makes `nats.Connect()` retry instead of fail-fast. No hard `depends_on: service_healthy` sequencing needed. |
| Silent TCP hang (network partition, no OS socket error) | Medium | `PingInterval(20s)` + `MaxPingsOutstanding(5)` — dead connection detected and closed in ≤100s, triggering reconnect. |
| Slow consumer — service can't keep up with message rate, server disconnects client | Medium | `ErrorHandler` logs `nats.ErrSlowConsumer` + `sub.Dropped()` count locally before server cuts the connection. Scale via additional queue group members (no config change needed). |
| NATS message headers (`x-session`, `x-admin-secret`) require NATS server ≥ 2.2 | Medium | `nats:latest` is NATS 2.x. Pin `nats:2-alpine` in docker-compose and Helm. |
| `handlers.go` in all 4 services still imports `internlamqp` — easy to miss | Medium | `go build ./...` fails immediately on stale imports. CI gate. |
| `health.AMQPHandler` registered in all 4 service `main.go` | Low | Compiler error is immediate on rename. |
| `producer/handlers.go` `call()` signature removes `correlationID` | Low | One call site in `proxyHandler`. Compiler error is immediate. |
| `X-Correlation-Id` response header removed | Low | Check frontend and integration tests for assertions on this header. |
| Prometheus metric renames (`amqp_*` → `nats_*`, `rabbitmq_connected` → `nats_connected`) | Low | Update Grafana dashboards in the same PR. |


---

## Phase 6 — NATS `micro` Package (Optional, post Phase 5)

The `nats/micro` package is a first-class microservices framework built into `nats.go`. It wraps `QueueSubscribe` with built-in service discovery, per-endpoint stats, and health pings — replacing the manual `health.NATSHandler` registration in every service.

**New file:** `internal/nats/micro_consumer.go` *(replaces `internal/nats/consumer.go`)*

**What changes vs Phase 2's `QueueSubscribe` consumer:**

| Phase 2 (`QueueSubscribe`) | Phase 6 (`nats/micro`) |
|---|---|
| Manual `health.NATSHandler` on `"health"` subject | `$SRV.PING.<name>` built-in — `nats micro ping` |
| No request count or latency stats | `$SRV.STATS.<name>` — per-endpoint counts, errors, avg latency |
| No service listing | `$SRV.INFO.<name>` — `nats micro ls` lists all running instances |
| Single `QueueSubscribe` dispatches to `switch action` | One `AddEndpoint` per action → each action independently subscribable |

### Phase 6a — Rewrite `internal/nats/consumer.go` using `nats/micro`

```go
// internal/nats/micro_consumer.go
// Import path: github.com/nats-io/nats.go/micro

import "github.com/nats-io/nats.go/micro"

// MicroConsumer wraps nats/micro.Service; public API is identical to Consumer.
type MicroConsumer struct {
    url         string
    name        string        // service name: "auth-service", "account-service", etc.
    version     string        // semver: "1.0.0"
    logger      *slog.Logger
    metrics     *metrics.ConsumerMetrics
    handlers    map[string]Handler  // registered by WithHandler(action, handler)
}

func (c *MicroConsumer) Run(ctx context.Context) {
    nc, err := nats.Connect(c.url,
        nats.Name(c.name),
        nats.MaxReconnects(-1),
        nats.ReconnectWait(2*time.Second),
        nats.ReconnectJitter(500*time.Millisecond, 2*time.Second),
        nats.RetryOnFailedConnect(true),
        nats.PingInterval(20*time.Second),
        nats.MaxPingsOutstanding(5),
        nats.ReconnectHandler(func(nc *nats.Conn) {
            if c.metrics != nil { c.metrics.ReconnectsTotal.Inc() }
            c.logger.Info("nats_reconnected", "url", nc.ConnectedUrl())
        }),
        nats.DisconnectErrHandler(func(_ *nats.Conn, err error) {
            c.logger.Error("nats_disconnected", "error", err)
        }),
    )
    if err != nil {
        c.logger.Error("nats_connect_failed", "error", err)
        return
    }
    defer nc.Drain()

    // micro.AddService registers the service and starts responding to $SRV.* subjects.
    svc, err := micro.AddService(nc, micro.Config{
        Name:        c.name,    // "auth-service" → $SRV.PING.auth-service
        Version:     c.version, // "1.0.0"
        Description: fmt.Sprintf("%s RPC handler", c.name),
    })
    if err != nil {
        c.logger.Error("micro_add_service_failed", "error", err)
        return
    }

    // Register one endpoint per registered handler (replaces single QueueSubscribe).
    // Subject: "banking.auth.<action>" — each action is independently subscribable.
    for action, h := range c.handlers {
        handler := h  // capture loop var
        subject := fmt.Sprintf("banking.%s.%s", c.name, action)  // e.g. banking.auth.login
        if err := svc.AddEndpoint(action,
            micro.HandlerFunc(func(req micro.Request) {
                go c.dispatchMicro(ctx, req, action, handler)
            }),
            micro.WithEndpointSubject(subject),
        ); err != nil {
            c.logger.Error("micro_add_endpoint_failed", "action", action, "error", err)
        }
    }

    c.logger.Info("nats_micro_service_started", "name", c.name, "version", c.version)
    <-ctx.Done()
}

func (c *MicroConsumer) dispatchMicro(ctx context.Context, req micro.Request, action string, h Handler) {
    if ctx.Err() != nil { return }
    var rpcReq rpcRequest
    if err := json.Unmarshal(req.Data(), &rpcReq); err != nil {
        req.Error("400", "invalid request body", nil)
        return
    }
    headers := map[string]string{
        "x-session":      req.Headers().Get("x-session"),
        "x-admin-secret": req.Headers().Get("x-admin-secret"),
    }
    result, _ := h(ctx, action, rpcReq.Payload, headers)
    body, _ := json.Marshal(result)
    req.Respond(body)
}
```

### Phase 6b — Subject-per-action routing (removes `action` JSON field)

With `micro.WithEndpointSubject`, the subject already encodes the action — the JSON body's `action` field becomes redundant. The `rpcRequest` struct simplifies:

```go
// Before (Phase 2 rpcRequest)
type rpcRequest struct {
    Action  string            `json:"action"`
    Payload json.RawMessage   `json:"payload"`
    Headers map[string]string `json:"headers,omitempty"` // moved to NATS headers
}

// After (Phase 6 rpcRequest — action removed)
type rpcRequest struct {
    Payload json.RawMessage `json:"payload"`
}
```

The producer's `pathToQueue` also changes from a single queue-per-service to a full action subject:

```go
// producer/handlers.go — Phase 6 pathToQueue + actionFromPath
func subjectFromPath(method, path string) string {
    switch {
    case path == "/api/auth/login":           return "banking.auth.login"
    case path == "/api/auth/register":        return "banking.auth.register"
    case path == "/api/account/balance":      return "banking.account.balance"
    case path == "/api/transfer/send":        return "banking.transfer.send"
    case path == "/api/notifications/list":   return "banking.notification.list"
    default:                                  return ""
    }
}
```

**Benefits at Phase 6:**
- `nats micro ls` — lists all running service instances with version
- `nats micro info auth-service` — shows all endpoints and metadata
- `nats micro stats auth-service` — shows per-endpoint request count, error count, average latency
- Each action is a first-class independently monitorable subject
- `health.NATSHandler` can be removed — `$SRV.PING.<name>` replaces it natively

**Recommendation:** Phase 6 is a significant refactor on top of a working migration. Implement Phases 1–5 first, validate in staging, then migrate to `micro` as a separate PR.

---

## Recommended Execution Order

### Core migration (Phases 1–5) — ✅ complete

1. ✅ **Phase 1** — `go.mod` dependencies swapped (`nats.go v1.52.0`; `amqp091-go` removed)
2. ✅ **Phase 2** — `internal/nats/consumer.go` created; `internal/amqp/` deleted
3. ✅ **Phase 3** — `producer/rpc.go` rewritten; `producer/metrics.go` updated; subjects renamed to `banking.*` hierarchy; `healthHandler` fixed
4. ✅ **Phase 4a** — `internal/service/service.go` updated (`Runner` field type → `*internnats.Consumer`)
5. ✅ **Phase 4b–c** — all 4 service `main.go` and `handlers.go` updated (import alias + queue constants)
6. ✅ **Phase 4d** — `health.NATSHandler` in place; `health.AMQPHandler` removed
7. ✅ **Phase 4e** — metric strings renamed to `nats_*` in `internal/metrics/metrics.go`
8. ✅ **Phase 5a** — `docker-compose.yml` updated (nats + nats-exporter; `NATS_URL`; `service_started` depends_on)
9. ✅ **Phase 5b** — Helm templates updated; all services use `NATS_URL`; `nats-connection-secret` Secret in `helm/templates/secret.yaml`; `nats.yaml` Deployment + Service + exporter in place; RabbitMQ references removed
10. ✅ `internal/amqp/` deleted; `ARCH-NATS-RPC.md` created

### Improvements (after core migration is stable)

> **Recommended order** — see ordering rationale in the HTML decision report.

11. ✅ **CQRS Tier 1b + Tier 2** (see [`cqrs-plan.md`](./cqrs-plan.md)) — `user_cache` stale balance bug fixed; `transferResult` carries phones + post-TX balances; `PublishTransferCompleted` pipeline (DEL + HSET + PUBLISH) in `internal/redis`; `handleBalance` in `account-service` reads from Redis hash first, DB fallback with warm-up; `GetBalance`/`SetBalance` helpers in `internal/redis`.
12. ✅ **Phase 6a** — `internal/nats/consumer.go` rewritten with `nats/micro`; `micro.AddService` + `AddEndpoint`; `$SRV.PING`, `$SRV.STATS`, `$SRV.INFO` built-in; per-endpoint latency and error counts visible via `nats micro stats <name>`.
13. ✅ **Phase 6b** — per-action subjects (`banking.auth.login`, `banking.account.balance`, etc.); `rpcRequest` simplified to `{Payload any}`; `subjectFromPath` exhaustive switch in `producer/handlers.go`; auth headers travel as NATS message headers only; `action` JSON field removed. CQRS Tier 1a superseded.
14. ✅ **CQRS Tier 3** (see [`cqrs-plan.md`](./cqrs-plan.md)) — `BANKING_EVENTS` stream (`InitStream` idempotent); `PublishTransferEvent` with `Nats-Msg-Id` in `transfer-service`; durable pull consumer `account-service-balance` (`DeliverAllPolicy`) in `account-service`; graceful degradation when `-js` absent; `-js` + `natsdata` volume in `docker-compose.yml`; PVC + conditional args in `helm/templates/nats.yaml`.
15. ✅ **CQRS Tier 1a superseded** — per-action subjects (item 13) produce finer-grained NATS subjects than the `.commands`/`.queries` split; Tier 1a skipped as planned.
16. ✅ **Phase 5 follow-up** — sampled `Nats-Trace-Dest` header in `producer/rpc.go`; 1% sample rate default; tunable via `NATS_TRACE_SAMPLE_RATE` env var (0–1); trace subject `banking.trace.rpc.<action-subject>`; transparent to consumers (NATS 2.11+ strips before delivery).
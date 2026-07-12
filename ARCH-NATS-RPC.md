# NATS RPC Architecture

## Overview

This project uses NATS for synchronous request/reply between [`api-producer`](producer/main.go) and
the backend consumer services. The implementation uses NATS Core request/reply via the
**`nats/micro` service framework** — the server transparently creates an ephemeral inbox subject per
request and routes the reply back to the caller without any per-request queue declarations or
correlation IDs.

## Subject hierarchy

Each service registers one `nats/micro` endpoint per action. The subject encodes both the service
and the action, making per-action observability (latency, error count) available natively via
`nats micro stats <name>`.

### RPC subjects (Core NATS — request/reply)

| Service | Endpoint action | Full subject |
|---------|----------------|-------------|
| auth-service | `register` | `banking.auth.register` |
| auth-service | `login` | `banking.auth.login` |
| auth-service | `health` | `banking.auth.health` |
| account-service | `me` | `banking.account.me` |
| account-service | `balance` | `banking.account.balance` |
| account-service | `lookup` | `banking.account.lookup` |
| account-service | `stats` | `banking.account.stats` |
| account-service | `users` | `banking.account.users` |
| account-service | `transfers` | `banking.account.transfers` |
| account-service | `notifications` | `banking.account.notifications` |
| account-service | `user-detail` | `banking.account.user-detail` |
| account-service | `health` | `banking.account.health` |
| transfer-service | `transfer` | `banking.transfer.transfer` |
| transfer-service | `health` | `banking.transfer.health` |
| notification-service | `notifications` | `banking.notification.notifications` |
| notification-service | `health` | `banking.notification.health` |

### JetStream event subjects (durable — no reply)

| Subject | Publisher | Stream |
|---------|-----------|--------|
| `banking.events.transfer.completed` | transfer-service | `BANKING_EVENTS` |

`banking.events.>` is captured by the `BANKING_EVENTS` stream (30-day retention, `LimitsPolicy`,
5-minute deduplication window keyed on `Nats-Msg-Id`).

## Request/reply flow

1. An HTTP request reaches [`api-producer`](producer/main.go).
2. [`subjectFromPath()`](producer/handlers.go) maps the exact request path to one of the RPC subjects
   above (exhaustive switch — unknown paths return `""` → HTTP 404 without a NATS round-trip).
3. [`rpcClient.call()`](producer/rpc.go) marshals an `rpcRequest` envelope, optionally injects a
   `Nats-Trace-Dest` header (1% sampled, rate tunable via `NATS_TRACE_SAMPLE_RATE`), and calls
   `nc.RequestMsgWithContext(ctx, msg)` — NATS sets `msg.Reply` to an auto-generated inbox
   (`_INBOX.<token>`) and delivers the reply directly to the caller's goroutine.
4. The target consumer's `nats/micro` endpoint reads from its registered action subject, runs the
   handler via [`Consumer.dispatch()`](internal/nats/consumer.go), and calls `req.Respond(data)`.
5. `call()` returns the decoded `rpcResponse` containing `Status` (HTTP status code) and `Body`
   (raw JSON).

## nats/micro service framework

Each consumer service calls `micro.AddService` + one `svc.AddEndpoint` per action. This provides:

| Built-in | Subject | Command |
|----------|---------|---------|
| Service ping | `$SRV.PING.<name>` | `nats micro ping` |
| Service info | `$SRV.INFO.<name>` | `nats micro info <name>` |
| Per-action stats | `$SRV.STATS.<name>` | `nats micro stats <name>` |

`$SRV.STATS` shows per-endpoint request count, error count, processing time, and last error —
without any custom Prometheus queries. This complements `nats_messages_total` and
`nats_handler_duration_seconds`.

Queue group: each endpoint uses its full subject as the queue group
(`banking.account.balance` etc.) so multiple replicas of the same service load-balance correctly
without any additional configuration.

## RPC envelope

```go
// Request — JSON body of NATS message (Phase 6b: action is in the subject, not the body)
type rpcRequest struct {
    Payload any `json:"payload"` // POST body or GET query params
}

// Response — JSON body of NATS reply
type rpcResponse struct {
    Status int             `json:"status"` // HTTP status code
    Body   json.RawMessage `json:"body"`
}
```

Auth headers (`x-session`, `x-admin-secret`) travel exclusively as NATS message headers, not in
the JSON body — consumers read them via `req.Headers().Get("x-session")`.

## Session propagation

```go
// producer/rpc.go — headers set on every NATS message
hdr := nats.Header{
    "x-session":      []string{r.Header.Get("X-Session")},
    "x-admin-secret": []string{r.Header.Get("X-Admin-Secret")},
}
// Optional sampled trace header (NATS 2.11+ server-level distributed tracing)
if rand.Float64() < natsTraceSampleRate {
    hdr["Nats-Trace-Dest"] = []string{"banking.trace.rpc." + subject}
}
```

The `RequireSession` middleware inside `Consumer.dispatch` extracts `x-session`, resolves the user
ID via Redis, and stores it in the handler context. Handlers retrieve it via
`nats.UserIDFromContext(ctx)`.

## JetStream event bus (BANKING_EVENTS)

Transfer-service publishes a durable event after every committed transfer with a deduplication
header:

```go
// internal/nats/jetstream.go
js.PublishMsg(ctx, &nats.Msg{
    Subject: "banking.events.transfer.completed",
    Data:    eventJSON,
    Header:  nats.Header{"Nats-Msg-Id": []string{strconv.Itoa(int(transferID))}},
})
```

Account-service runs a durable pull consumer (`account-service-balance`) with `DeliverAllPolicy`.
On every restart it resumes from the last ACK offset. After a Redis wipe it replays the full stream
and rebuilds the `balance` hash without a single DB read.

Both services degrade gracefully when the NATS server has no `-js` flag: a `WARN` log is emitted
and the services continue with Tier 2 Redis-only operation.

## Connection sharing

Transfer-service and account-service each call `internnats.Connect()` once at startup and pass the
resulting `*nats.Conn` to both the `Consumer` (via `WithConn(nc)`) and `InitStream` for JetStream.
This means one TCP connection to NATS per service process — not one per feature.

```go
// services/transfer-service/main.go (simplified)
nc, _ := internnats.Connect(cfg.NATSURL, serviceName, logger, m.ReconnectsTotal.Inc)
defer nc.Drain()

js, _ := internnats.InitStream(ctx, nc)   // JetStream context
consumer := internnats.NewConsumer(...,
    internnats.WithConn(nc),              // share the same connection
    ...
)
```

## Why NATS over AMQP

| Concern | AMQP (RabbitMQ) | NATS |
|---------|----------------|------|
| Request/reply | Manual: per-request callback queue, `reply_to`, `correlation_id` | Native inbox-per-request, no setup needed |
| Connection state | Channels, exchanges, queue declarations | Single connection, subjects |
| Reply routing | Broker re-delivers through exchange | Direct: server injects reply into inbox |
| Reconnect | Re-declare topology on reconnect | Auto-reconnect, no topology to restore |
| Operational overhead | Management UI, users, vhosts, policies | Single binary, no persistence by default |
| Per-endpoint observability | External tooling required | Built-in via `$SRV.STATS` |
| Durable event log | Separate persistent queues per consumer | JetStream streams — single stream, multiple consumer views |

## Previous architecture

The previous architecture used RabbitMQ AMQP with per-request exclusive auto-delete callback
queues and a single `banking.*.requests` subject per service. See the git history for
`ARCH-RMQ-RPC.md` (deleted in Phase 5c of the migration) and
[`fork-docs/amqp-to-nats-migration.md`](fork-docs/amqp-to-nats-migration.md) for the full
migration plan.

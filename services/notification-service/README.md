# notification-service

NATS RPC consumer **and** WebSocket server. Two transports run concurrently in a single process
under the same root context:

- **NATS** — `nats/micro` endpoint on `banking.notification.notifications`; returns the user's notification history.
- **HTTP/WebSocket** — serves `GET /ws`; streams real-time notifications from Redis pub/sub to the connected browser.

## Actions (NATS)

| Action | NATS subject | Path | Method | Auth | Description |
|--------|-------------|------|--------|------|-------------|
| `notifications` | `banking.notification.notifications` | `/api/notifications/notifications` | `GET` | session | Last 50 notifications for the authenticated user |
| `health` | `banking.notification.health` | `/api/notifications/health` | `GET` | none | Readiness check (DB + Redis ping) |

### notifications

**Response:**
```json
{
  "notifications": [
    {
      "id": 101,
      "user_id": 7,
      "message": "You received ************ from alice",
      "is_read": false,
      "created_at": "2025-01-01T12:00:00Z"
    }
  ]
}
```

Returns at most 50 records, ordered by `created_at DESC`.

## WebSocket (`GET /ws`)

Kong forwards `GET /ws` directly to this service (bypassing the NATS bus entirely).

**Connection:**
```
ws://host/ws?session=<session-token>
```

The session token is validated before the WebSocket upgrade. An invalid or missing token returns
`401` before the upgrade occurs.

**Message format** (server → client):
```json
{ "message": "{\"transfer_id\":42,\"amount\":500,\"sender_id\":1,\"sender_balance\":95000,\"receiver_id\":7,\"receiver_balance\":105000}" }
```

The inner JSON string is the serialized `redis.TransferCompleted` published by `transfer-service`
on commit. The client can parse it for real-time balance and notification updates.

**Lifecycle:**

```
connect
  └─ validate session → 401 if invalid
  └─ WebSocket upgrade
  └─ SubscribeNotify(userID) → Redis notify:{userID} channel
  └─ goroutine A: presence heartbeat (SetPresence online, every presenceTTL/3)
  └─ main loop: pump notify channel → ws.Write
disconnect (client close, server shutdown, or write error)
  └─ SetPresence offline (uses context.Background — wsCtx already cancelled)
  └─ unsubscribe from Redis
```

**Presence TTL:** controlled by `PRESENCE_TTL_SECONDS` (default 60 s). The heartbeat interval is
automatically derived as `PRESENCE_TTL_SECONDS / 3` — the invariant (heartbeat fires before key
expires) is self-enforcing.

Note: WebSocket fan-out uses Redis pub/sub, not JetStream. Real-time delivery with no history replay
required is the correct choice here — see `fork-docs/cqrs-plan.md §3f` for the rationale.

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | HTTP readiness — `200` when DB + Redis reachable |
| `GET` | `/metrics` | Prometheus scrape endpoint |
| `GET` | `/ws` | WebSocket upgrade (`?session=<token>` required) |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8004` | HTTP/WebSocket listen port |
| `NATS_URL` | `nats://nats:4222` | NATS connection URL |
| `DATABASE_URL` | `postgresql://banking:bankingpass@postgres:5432/banking` | PostgreSQL DSN |
| `REDIS_URL` | `redis://redis:6379/0` | Redis connection URL |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | _(empty — disabled)_ | OTLP/gRPC tracing endpoint |
| `DB_POOL_SIZE` | `15` | pgx pool max connections |
| `SESSION_TTL_SECONDS` | `86400` | Session expiry in seconds |
| `PRESENCE_TTL_SECONDS` | `60` | Redis presence key TTL; heartbeat = TTL ÷ 3 |

## Running locally

```bash
cd services/notification-service
DATABASE_URL="postgresql://banking:bankingpass@localhost:5432/banking" \
REDIS_URL="redis://localhost:6379/0" \
NATS_URL="nats://localhost:4222" \
go run .
```

## Building

```bash
docker build -f services/notification-service/Dockerfile -t notification-service .
```

## File layout

```
services/notification-service/
├── main.go      — config, RequireSession wiring, consumer + HTTP server, graceful shutdown
├── handlers.go  — handleNotifications (NATS)
├── ws.go        — wsHandler: WebSocket upgrade, SubscribeNotify loop, presence heartbeat
├── Dockerfile
├── go.mod
└── go.sum
```

## Concurrency model

The service runs three goroutines under a shared `errgroup`:

```
main goroutine
├─ g.Go: consumer.Run(ctx)        ← NATS subscription lifecycle (blocks, reconnects)
├─ g.Go: server.ListenAndServe()  ← HTTP + WebSocket
└─ g.Go: signal handler           ← SIGINT/SIGTERM → server.Shutdown + ctx cancel
```

Each WebSocket connection adds two goroutines:
- **Heartbeat goroutine** — ticks at `PresenceTTL()/3`; exits when `wsCtx` is cancelled.
- **Main loop** — pumps Redis messages to the WebSocket write; also in the `wsHandler` goroutine.

`conn.CloseRead()` is used per the `coder/websocket` docs for write-only connections: it drains
incoming frames (ping/pong/close) and cancels `wsCtx` when the connection closes, which unblocks
the pump loop and stops the heartbeat goroutine.

## Observability

**Logs** — JSON via `log/slog`.

Key log events:

| Event (`msg`) | Level | Description |
|---------------|-------|-------------|
| `ws_connected` | INFO | WebSocket connection established; includes `user_id` |
| `ws_disconnected` | INFO | Connection closed cleanly |
| `ws_write_failed` | INFO | Write error (connection drop, not a server error) |
| `ws_upgrade_failed` | INFO | WebSocket upgrade rejected |
| `notifications_request` | INFO | NATS notification fetch; includes `user_id`, `count` |
| `nats_micro_service_started` | INFO | `nats/micro` service registered |
| `nats_handler_error` | ERROR | Unhandled error in handler |

**Metrics** — `GET /metrics`. Includes `nats_messages_total`, `nats_handler_duration_seconds`,
`nats_reconnects_total` (all labelled `service="notification-service"`).

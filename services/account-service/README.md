# account-service

NATS RPC consumer that handles user account operations and admin management. Uses the `nats/micro`
framework with per-action subjects under the `banking.account.*` prefix. Backed by PostgreSQL and
Redis (session validation, balance read model, JetStream balance projection).

All user-facing actions require a valid session (`x-session` NATS header). Admin actions
additionally require the `x-admin-secret` header. Both checks are enforced by middleware at handler
registration — handler code itself is auth-free.

## Actions

### User actions

| Action | NATS subject | Path | Method | Auth | Description |
|--------|-------------|------|--------|------|-------------|
| `me` | `banking.account.me` | `/api/account/me` | `GET` | session | Authenticated user's profile |
| `balance` | `banking.account.balance` | `/api/account/balance` | `GET` | session | Current balance (Redis hash → DB fallback) |
| `lookup` | `banking.account.lookup` | `/api/account/lookup` | `GET` | session | Look up another user by account number, phone, or username |
| `health` | `banking.account.health` | `/api/account/health` | `GET` | none | Readiness check |

### Admin actions

All admin actions require both `x-session` (valid admin session) and `x-admin-secret`.

| Action | NATS subject | Path | Method | Description |
|--------|-------------|------|--------|-------------|
| `stats` | `banking.account.stats` | `/api/account/stats` | `GET` | Aggregate counts: user count, transfer count, total balance |
| `users` | `banking.account.users` | `/api/account/users` | `GET` | Paginated user list; optional `search` ILIKE filter |
| `transfers` | `banking.account.transfers` | `/api/account/transfers` | `GET` | Paginated transfer list with sender/receiver usernames |
| `notifications` | `banking.account.notifications` | `/api/account/notifications` | `GET` | Paginated notification list |
| `user-detail` | `banking.account.user-detail` | `/api/account/user-detail` | `GET` | Full profile for a single user by `user_id` |

### Payload examples

**lookup:**
```json
{ "account_number": "123456789012" }
{ "phone": "0912345678" }
{ "username": "alice" }
```

**users (admin):**
```json
{ "page": "1", "size": "20", "search": "alice" }
```
`search` applies an ILIKE filter across `username`, `phone`, and `account_number` simultaneously.

**user-detail (admin):**
```json
{ "user_id": "7" }
```

### Pagination

`page` and `size` are accepted as string query params in the payload. Defaults: `page=1`, `size=20`, maximum `size=100`.

## Balance read model

`handleBalance` implements a two-tier read strategy:

1. **Redis Hash `balance`** — `HGet("balance", userID)` O(1). Written by `transfer-service`'s post-commit pipeline (`HSET balance {senderID} {bal}`) on every transfer.
2. **PostgreSQL fallback** — on a miss (cold start, Redis restart, first request for a user who has never transferred), queries `users.balance` and calls `SetBalance` to warm the hash for next time.

**JetStream balance projection** (`runBalanceProjection` goroutine):

- Runs a durable pull consumer (`account-service-balance`) on the `BANKING_EVENTS` JetStream stream
- `DeliverAllPolicy`: replays the full event log from sequence 0 on first start or after a Redis wipe — rebuilds the entire `balance` hash without a single DB round-trip
- On restart: resumes from the last ACK offset (durable) — no full replay
- `MaxAckPending=100`, `BackOff=[2s,10s,30s]`
- If JetStream is unavailable (`NATS` without `-js`), a `WARN` is logged and the goroutine is not started; the Tier 2 Redis pipeline + DB fallback keeps `balance` working

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | HTTP readiness check — `200` when DB + Redis are reachable |
| `GET` | `/metrics` | Prometheus scrape endpoint |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8002` | HTTP listen port |
| `NATS_URL` | `nats://nats:4222` | NATS connection URL |
| `DATABASE_URL` | `postgresql://banking:bankingpass@postgres:5432/banking` | PostgreSQL DSN |
| `REDIS_URL` | `redis://redis:6379/0` | Redis connection URL |
| `ADMIN_SECRET` | `banking-admin-2025` | Shared admin secret — **change this in production** |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | _(empty — disabled)_ | OTLP/gRPC tracing endpoint |
| `DB_POOL_SIZE` | `15` | pgx pool max connections |
| `SESSION_TTL_SECONDS` | `86400` | Session expiry in seconds |

## Running locally

```bash
cd services/account-service
DATABASE_URL="postgresql://banking:bankingpass@localhost:5432/banking" \
REDIS_URL="redis://localhost:6379/0" \
NATS_URL="nats://localhost:4222" \
ADMIN_SECRET="dev-secret" \
go run .
```

NATS must be running with `-js` to enable the balance projection consumer. Without it the service
logs a warning and continues serving balance via the Tier 2 Redis hash + DB fallback.

## Building

```bash
docker build -f services/account-service/Dockerfile -t account-service .
```

## File layout

```
services/account-service/
├── main.go      — config, Connect (shared NATS conn), InitStream, balance projection goroutine,
│                  middleware wiring, consumer + HTTP server, graceful shutdown
├── handlers.go  — handleMe, handleBalance, queryBalanceFromDB, handleLookup, paginate helper
├── admin.go     — handleAdminStats, handleAdminUsers, handleAdminTransfers,
│                  handleAdminNotifications, handleAdminUserDetail
├── Dockerfile
├── go.mod
└── go.sum
```

## Auth middleware wiring

Auth is applied once at registration in `main.go`, not inside handler functions:

```go
requireSession := internnats.SessionMiddleware(d.RedisClient)
requireAdmin   := internnats.AdminMiddleware(cfg.AdminSecret, d.RedisClient)

internnats.WithHandler("balance", requireSession(handleBalance(d.BDB, d.RedisClient, logger)))
internnats.WithHandler("stats",   requireAdmin(handleAdminStats(d.BDB, logger)))
```

User ID is available inside handler bodies via `internnats.UserIDFromContext(ctx)`.

## Observability

**Logs** — JSON via `log/slog`; every line carries `"service":"account-service"`.

Key log events:

| Event (`msg`) | Level | Description |
|---------------|-------|-------------|
| `me_request` | INFO | Profile fetch; includes `user_id` |
| `balance_request` | INFO | Balance fetch; amount logged as HMAC via `MaskAmount` |
| `lookup_request` | INFO | User lookup; account number masked |
| `balance_projection_started` | INFO | JetStream pull consumer active; stream + consumer name |
| `balance_projection_updated` | INFO | Balance hash updated from event; `transfer_id`, sender/receiver IDs |
| `balance_projection_redis_error` | ERROR | Redis HSET failed; message will be NakWithDelay retried |
| `jetstream_unavailable_balance_projection_disabled` | WARN | NATS has no `-js`; projection disabled |
| `nats_micro_service_started` | INFO | `nats/micro` service registered |
| `nats_handler_error` | ERROR | Unhandled error in a handler |

**Metrics** — `GET /metrics`. Includes `nats_messages_total`, `nats_handler_duration_seconds`,
`nats_reconnects_total` (all labelled `service="account-service"`).

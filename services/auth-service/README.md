# auth-service

NATS RPC consumer that handles user registration and login. Uses the `nats/micro` framework with
per-action subjects under the `banking.auth.*` prefix. Backed by PostgreSQL (user storage) and
Redis (session tokens, user cache).

## Actions

| Action | NATS subject | Path | Method | Description |
|--------|-------------|------|--------|-------------|
| `register` | `banking.auth.register` | `/api/auth/register` | `POST` | Create a new user account |
| `login` | `banking.auth.login` | `/api/auth/login` | `POST` | Authenticate and return a session token |
| `health` | `banking.auth.health` | `/api/auth/health` | `GET` | Readiness check (DB + Redis ping) |

### register

**Payload:**
```json
{ "phone": "0912345678", "username": "alice", "password": "secret" }
```

**Response:**
```json
{ "id": 1, "phone": "09****78", "username": "alice", "account_number": "123456789012", "balance": 100000 }
```

- Phone must be digits only and unique.
- A unique 12-digit account number is generated (up to 20 collision-free attempts).
- Password is hashed with bcrypt before storage.
- Duplicate phone returns `409`; duplicate username detected via PostgreSQL SQLSTATE `23505`.

### login

**Payload** (phone or username, not both required):
```json
{ "phone": "0912345678", "password": "secret" }
```

**Response:**
```json
{
  "session": "uuid-v4-token",
  "phone": "09****78",
  "username": "alice",
  "account_number": "123456789012",
  "balance": 100000,
  "is_admin": false
}
```

- Checks Redis user cache first (`user_cache:phone:{phone}` or `user_cache:username:{username}`); falls back to DB on miss and populates both cache keys.
- Returns `401` for unknown user or wrong password. The two cases return an identical response to prevent user enumeration.
- Session token TTL is controlled by `SESSION_TTL_SECONDS` (default 24 h).

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | HTTP readiness check — `200` when DB + Redis are reachable |
| `GET` | `/metrics` | Prometheus scrape endpoint |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8001` | HTTP listen port |
| `NATS_URL` | `nats://nats:4222` | NATS connection URL |
| `DATABASE_URL` | `postgresql://banking:bankingpass@postgres:5432/banking` | PostgreSQL DSN |
| `REDIS_URL` | `redis://redis:6379/0` | Redis connection URL |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | _(empty — disabled)_ | OTLP/gRPC tracing endpoint |
| `DB_POOL_SIZE` | `15` | pgx pool max connections |
| `BCRYPT_ROUNDS` | `10` | bcrypt work factor |
| `SESSION_TTL_SECONDS` | `86400` | Session expiry in seconds |
| `USER_CACHE_TTL_SECONDS` | `300` | Redis user-cache TTL in seconds |

## Running locally

```bash
# Prerequisites: Go 1.26+, running PostgreSQL + Redis + NATS

cd services/auth-service
DATABASE_URL="postgresql://banking:bankingpass@localhost:5432/banking" \
REDIS_URL="redis://localhost:6379/0" \
NATS_URL="nats://localhost:4222" \
go run .
```

## Building

```bash
# From the repo root (Dockerfile copies from the repo context)
docker build -f services/auth-service/Dockerfile -t auth-service .
```

## File layout

```
services/auth-service/
├── main.go      — config parsing, dependency wiring, graceful shutdown
├── handlers.go  — handleRegister, handleLogin, genAccountNumber
├── crypto.go    — randomDigits (cryptographically secure)
├── Dockerfile
├── go.mod
└── go.sum
```

## Observability

**Logs** — JSON via `log/slog`; every line carries `"service":"auth-service"`.

Key log events:

| Event (`msg`) | Level | Description |
|---------------|-------|-------------|
| `register_success` | INFO | New user created; includes `user_id`, `username` |
| `login_success` | INFO | Successful login; includes `user_id`, `username` |
| `login_failed` | INFO | Bad credentials; includes `reason` (`user_not_found` / `invalid_password`) |
| `set_user_cache_failed` | WARN | Redis cache write failed (non-fatal; login still succeeds) |
| `nats_micro_service_started` | INFO | `nats/micro` service registered; shows endpoint count |
| `nats_reconnected` | INFO | Re-connected to NATS after a disconnect |
| `nats_handler_error` | ERROR | Unhandled error in a handler |

**Metrics** — `GET /metrics` (Prometheus). Includes `nats_messages_total`,
`nats_handler_duration_seconds`, `nats_reconnects_total` (all labelled `service="auth-service"`).

**Tracing** — OTel spans emitted when `OTEL_EXPORTER_OTLP_ENDPOINT` is set.

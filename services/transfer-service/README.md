# transfer-service

NATS RPC consumer that performs atomic balance transfers between users. Subscribes to
`banking.transfer.*` subjects via a `nats/micro` endpoint (`banking.transfer.transfer`). Backed by
PostgreSQL (SERIALIZABLE transactions with SELECT FOR UPDATE), Redis (post-commit pipeline), and
NATS JetStream (durable event publish).

This is the most correctness-critical service in the stack.

## Actions

| Action | NATS subject | Path | Method | Auth | Description |
|--------|-------------|------|--------|------|-------------|
| `transfer` | `banking.transfer.transfer` | `/api/transfer/transfer` | `POST` | session | Transfer funds from the authenticated user to another |
| `health` | `banking.transfer.health` | `/api/transfer/health` | `GET` | none | Readiness check (DB + Redis ping) |

### transfer

**Payload:**
```json
{
  "account_number": "123456789012",
  "amount": 5000
}
```

The receiver is identified by exactly one of: `account_number`, `phone`, or `username`. `amount`
must be a positive integer (integer currency units).

**Success response:**
```json
{ "transfer_id": 42, "amount": 5000 }
```

**Error responses:**

| Status | Condition |
|--------|-----------|
| `400` | `amount` ≤ 0, or no receiver identifier provided |
| `400` | Insufficient funds |
| `400` | Self-transfer (sender = receiver) |
| `401` | Missing or expired session |
| `404` | Receiver not found |
| `500` | Internal error (DB, Redis) |

## Correctness guarantees

The `handleTransfer` implementation enforces five properties simultaneously:

1. **SERIALIZABLE isolation** — `db.SerializableTx` opens the transaction at `sql.LevelSerializable`. This prevents phantom reads during the balance check.

2. **Deterministic lock ordering** — the user row with the lower ID is always locked first via `SELECT FOR UPDATE`. This prevents deadlocks when two users transfer to each other concurrently (e.g. Alice→Bob and Bob→Alice at the same time).

3. **Atomic writes** — balance debit, balance credit, `transfers` row insert, and two `notifications` row inserts all occur within the same transaction. A failure at any step rolls everything back.

4. **Tier 2 — Post-commit Redis pipeline** (single round-trip, non-fatal):
   - `DEL user_cache:phone:{senderPhone}`, `DEL user_cache:phone:{receiverPhone}` — invalidates stale cached balances so the next login reflects the new balance
   - `HSET balance {senderID} {postTXBalance}`, `HSET balance {receiverID} {postTXBalance}` — updates the balance read model used by account-service
   - `PUBLISH notify:{receiverID}` — real-time WebSocket event

   All five commands execute in a single Redis pipeline round-trip after the PostgreSQL commit. A Redis failure is logged as `WARN` — the transfer is already committed.

5. **Tier 3 — JetStream durable publish** (non-fatal):
   - Subject: `banking.events.transfer.completed`
   - `Nats-Msg-Id: {transferID}` — Gap-5 idempotency: if the HTTP caller retries the transfer after a timeout, the transfer ID is already committed to PostgreSQL and the duplicate JetStream publish is silently discarded by the server within the 5-minute dedup window
   - If JetStream is unavailable (NATS running without `-js`), logged as `WARN`; Redis pipeline (Tier 2) still runs

```
┌─ SerializableTx ─────────────────────────────────────────────┐
│  1. Resolve receiver (SELECT by account_number/phone/username)│
│  2. Lock lower-ID user row (SELECT FOR UPDATE)                │
│  3. Lock higher-ID user row (SELECT FOR UPDATE)               │
│  4. Validate balance                                          │
│  5. UPDATE sender balance (balance - amount)                  │
│  6. UPDATE receiver balance (balance + amount)                │
│  7. INSERT transfers row                                      │
│  8. INSERT 2 notifications rows                               │
└───────────────────────────────────────────────────────────────┘
  → COMMIT
  → Tier 2: Redis pipeline (DEL×2 + HSET×2 + PUBLISH) — single round-trip
  → Tier 3: JetStream publish (Nats-Msg-Id dedup) — if JS available
```

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | HTTP readiness — `200` when DB + Redis reachable |
| `GET` | `/metrics` | Prometheus scrape endpoint |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8003` | HTTP listen port |
| `NATS_URL` | `nats://nats:4222` | NATS connection URL |
| `DATABASE_URL` | `postgresql://banking:bankingpass@postgres:5432/banking` | PostgreSQL DSN |
| `REDIS_URL` | `redis://redis:6379/0` | Redis connection URL |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | _(empty — disabled)_ | OTLP/gRPC tracing endpoint |
| `DB_POOL_SIZE` | `15` | pgx pool max connections |
| `SESSION_TTL_SECONDS` | `86400` | Session expiry in seconds |
| `LOG_AMOUNT_SECRET` | _(default key)_ | HMAC key for masking transfer amounts in logs |

## Running locally

```bash
cd services/transfer-service
DATABASE_URL="postgresql://banking:bankingpass@localhost:5432/banking" \
REDIS_URL="redis://localhost:6379/0" \
NATS_URL="nats://localhost:4222" \
go run .
```

NATS must be running with `-js` to enable JetStream event publishing. Without it the service logs
a warning and continues — all transfers commit normally.

## Building

```bash
docker build -f services/transfer-service/Dockerfile -t transfer-service .
```

## File layout

```
services/transfer-service/
├── main.go      — config, Connect (shared NATS conn), InitStream, RequireSession wiring,
│                  consumer + HTTP server, graceful shutdown
├── handlers.go  — handleTransfer, runTransferTx, resolveReceiver, lockBothUsers,
│                  updateBalances, insertTransferRecord, insertNotifications
├── Dockerfile
├── go.mod
└── go.sum
```

## Observability

**Logs** — JSON via `log/slog`.

Key log events:

| Event (`msg`) | Level | Description |
|---------------|-------|-------------|
| `transfer_success` | INFO | Transfer committed; `transfer_id`, `sender_id`, `receiver_id`, masked amount |
| `post_commit_redis_pipeline_failed` | WARN | Redis pipeline failed (transfer still succeeded) |
| `jetstream_publish_failed` | WARN | JetStream event publish failed (transfer + Redis pipeline still succeeded) |
| `jetstream_unavailable_transfer_events_disabled` | WARN | NATS has no `-js` flag; JetStream publish disabled |
| `nats_micro_service_started` | INFO | `nats/micro` service registered; shows endpoint count |
| `nats_handler_error` | ERROR | Unhandled error in a handler (DB failure, etc.) |

Transfer amounts are always logged as a 12-character HMAC hex string via `logging.MaskAmount` — the exact amount is never written to logs.

**Metrics** — `GET /metrics`. Includes `nats_messages_total`, `nats_handler_duration_seconds`,
`nats_reconnects_total` (all labelled `service="transfer-service"`).

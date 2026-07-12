# CQRS Implementation Plan

Investigation of the Command Query Responsibility Segregation pattern against the current
architecture, with a graded implementation roadmap. Based on a full code read of all service
handlers, the shared `internal/` library, the DB layer, and the Redis key space.

---

## What CQRS is

CQRS separates the **write path** (commands — state-changing operations with side effects) from
the **read path** (queries — projections with no side effects) at every layer: API, application
logic, and optionally the data store. Commands go to a consistency-first write model; queries are
served from a performance-first read model kept in sync by events emitted after each command
commits. CQRS pairs naturally with event sourcing but does not require it.

---

## Current state — what already aligns with CQRS

The codebase has CQRS at the service boundary without being explicitly labelled as such.
Three findings stand out.

### Finding 1 — `account-service` is already a pure query service

Every handler in `services/account-service/handlers.go` and `services/account-service/admin.go`
is a `SELECT` or aggregate. There is not a single `INSERT`, `UPDATE`, or `DELETE` anywhere in the
service. It holds no write path whatsoever.

```
me          → SELECT FROM users WHERE id = $1
balance     → SELECT balance FROM users WHERE id = $1
lookup      → SELECT FROM users WHERE account_number|phone|username = $1
stats       → SELECT COUNT(*), SUM(balance) FROM users; COUNT(*) FROM transfers; COUNT(*) notifications
users       → SELECT FROM users [ILIKE search] LIMIT $size OFFSET $page
transfers   → SELECT FROM transfers JOIN username batch
notifications → SELECT FROM notifications LIMIT $size OFFSET $page
user-detail → SELECT FROM users WHERE id = $1
```

This is a query service. The split is real and enforced — it just hasn't been named.

### Finding 2 — `transfer-service` is already a pure command service

`services/transfer-service/handlers.go` contains the only write path for domain state:

```
SERIALIZABLE TX {
    SELECT … FOR UPDATE  (lock both users, deterministic order)
    UPDATE users SET balance = balance - amount  (debit sender)
    UPDATE users SET balance = balance + amount  (credit receiver)
    INSERT INTO transfers …
    INSERT INTO notifications × 2
}
POST-COMMIT: PUBLISH notify:{receiverID}
```

Zero read-only query handlers. Every action is a mutation or a health check.

### Finding 3 — The Redis pub/sub is already an event projection

After `runTransferTx` commits, `transfer-service` calls `iredis.PublishNotify`. In
`notification-service/ws.go`, a running `iredis.Subscribe` goroutine picks this up and pushes a
WebSocket frame to the connected client. The event is published only after the transaction
commits — a rolled-back transfer never emits an event. This is the most important CQRS invariant,
and it is already satisfied.

```
transfer command
  → SERIALIZABLE TX commits to PostgreSQL
  → PUBLISH notify:{receiverID}          ← event emitted post-commit only
  → notification-service SUBSCRIBE
  → WebSocket push to browser
```

### NATS action routing — command vs query at the message level

The `action` field in every NATS RPC envelope already separates commands from queries by
naming convention. The dispatch table in each service `main.go` makes this explicit:

| Action | Service | Type | Side effect |
|--------|---------|------|-------------|
| `register` | auth | **Command** | `INSERT INTO users` |
| `login` | auth | **Command** | `SET session:{sid}`, `SET user_cache:*` |
| `transfer` | transfer | **Command** | `UPDATE users`, `INSERT transfers`, `INSERT notifications`, `PUBLISH notify` |
| `me` | account | Query | none |
| `balance` | account | Query | none |
| `lookup` | account | Query | none |
| `stats / users / transfers / notifications / user-detail` | account | Query | none |
| `notifications` | notification | Query | none |

---

## Gaps — what is not yet separated

### Gap 1 — Shared write store; no read model

All services receive the same `DATABASE_URL` and connect to the same single PostgreSQL primary via
`internal/service/service.go:InitDeps`. `account-service` queries the same normalised tables that
`transfer-service` just wrote to. There is no dedicated read model, no denormalised projection,
and no read replica. Read-heavy admin queries (paginated users, transfer list with username joins)
compete directly with SERIALIZABLE write transactions for the same connection pool.

### Gap 2 — Balance is mutable state, not event-derived

`transfer-service/handlers.go` issues two `UPDATE users SET balance = balance ± amount` statements
inside the transaction. The current balance is a mutable integer on the `users` row. The
`transfers` table is append-only and is structurally an event log, but balance is stored as
derived mutable state rather than being computed from that log. The raw material for event sourcing
already exists; the derived column just hasn't been removed.

### Gap 3 — No NATS command/query bus split

Commands (`transfer`, `register`, `login`) and queries (`me`, `balance`, `lookup`) share
`banking.*.requests` queue-group subjects. Scaling the query path independently — e.g. connecting
a set of read-only `account-service` replicas to a PostgreSQL read replica — is not expressible
with the current single-subject-per-service model without adding routing logic that does not exist.

### Gap 4 — `user_cache` carries a stale balance after transfers

`auth-service` populates `user_cache:phone:{phone}` and `user_cache:username:{username}` on login,
including the `balance` field (`iredis.CachedUser.Balance`). `transfer-service` updates the DB
balance but never invalidates or updates either cache key. The `balance` handler in `account-service`
correctly bypasses this cache and queries the DB directly, so it is unaffected. However, the `login`
response uses the cached `CachedUser` struct and therefore returns a stale balance to the client
until the 5-minute TTL expires. This is a data correctness bug that full CQRS formalism surfaces
and forces to be addressed.

### Gap 5 — No transfer idempotency guard

A client network retry can re-submit a `transfer` action, which passes through NATS Core (at-most-once,
no deduplication) and reaches `transfer-service` again. The SERIALIZABLE transaction does not
protect against duplicate HTTP-level retries because each call is a fresh transaction with a new
`INSERT INTO transfers`. A double-charged transfer is silent and permanent. JetStream's
`Nats-Msg-Id` header provides exactly-once deduplication at the broker level when the producer
moves commands through a stream instead of bare Core NATS RPC.

---

## Implementation plan — three tiers

Each tier is independently deployable. Tier 1 fixes an active bug. Tiers 2 and 3 are driven by
load requirements.

---

### Tier 1 — Formalise the split and fix the cache bug ✅

**Effort: ~1 day.** No architectural change; refactoring + one bug fix.
**Status: Tier 1b implemented; Tier 1a superseded by Phase 6b (per-action subjects).**

#### 1a — Rename NATS subjects to express command/query intent

In `producer/handlers.go`, split `pathToQueue()` so that state-changing paths route to a
`.commands` subject and read-only paths route to a `.queries` subject:

```go
func pathToQueue(path string) string {
    switch {
    // Commands (state-mutating)
    case strings.HasPrefix(path, "/api/auth/register"):
        return "banking.auth.commands"
    case strings.HasPrefix(path, "/api/auth/login"):
        return "banking.auth.commands"
    case strings.HasPrefix(path, "/api/transfer/"):
        return "banking.transfer.commands"

    // Queries (read-only)
    case strings.HasPrefix(path, "/api/auth/health"):
        return "banking.auth.queries"
    case strings.HasPrefix(path, "/api/account/"):
        return "banking.account.queries"
    case strings.HasPrefix(path, "/api/notifications/"):
        return "banking.notification.queries"

    default:
        return ""
    }
}
```

Each service registers handlers on both its `.commands` and `.queries` subjects
(or a single subject for services that are command-only or query-only). No handler logic changes.

**Benefit:** command vs query latency, throughput, and error rates become separately observable in
Prometheus via `nats_messages_total{subject="banking.account.queries"}` vs
`nats_messages_total{subject="banking.transfer.commands"}`. Queue-group scaling of the query path
becomes independently expressible.

#### 1b — Invalidate `user_cache` on transfer commit ✅

In `transfer-service/handlers.go`, after `runTransferTx` succeeds, delete the stale cache keys for
both sender and receiver before (or pipelined with) the Redis `PUBLISH`. This requires the sender
and receiver phones to be returned from `runTransferTx` — add them to `transferResult`:

```go
type transferResult struct {
    transferID    int32
    receiverID    int
    senderPhone   string   // new — for cache invalidation
    receiverPhone string   // new — for cache invalidation
}
```

Inside `runTransferTx`, populate these from the already-fetched user rows (no extra query needed —
`lockBothUsers` already returns both `db.User` structs).

Post-commit pipeline in `handleTransfer`:

```go
// Pipeline: invalidate stale cache + publish event — single round-trip.
pipe := redisClient.Pipeline()
pipe.Del(ctx,
    "user_cache:phone:"+res.senderPhone,
    "user_cache:username:"+senderUsername,  // if available
    "user_cache:phone:"+res.receiverPhone,
    "user_cache:username:"+receiverUsername,
)
eventJSON, _ := json.Marshal(iredis.NotifyEvent{
    TransferID: res.transferID,
    Amount:     p.Amount,
})
pipe.Publish(ctx, fmt.Sprintf("notify:%d", res.receiverID), string(eventJSON))
_, _ = pipe.Exec(ctx)
```

---

### Tier 2 — Redis read model for balance ✅

**Effort: ~3 days.** Separates the hot `balance` query from the write DB. Eliminates the
read/write contention on the `users` table for the most frequent query path.
**Status: Implemented. `PublishTransferCompleted` pipeline in `internal/redis`; `handleBalance` with Redis-first + DB fallback in `account-service`.**

#### 2a — Expand `TransferCompleted` event to carry post-TX balances

The `runTransferTx` function already reads back both user rows after locking (`lockBothUsers`
returns `db.User` structs with the pre-TX balances). After the debit/credit `UPDATE` statements,
a `SELECT` or a `RETURNING` clause gives the post-TX values without a separate round-trip.
Extend `transferResult` and `iredis.NotifyEvent`:

```go
// internal/redis/redis.go
type TransferCompleted struct {
    TransferID      int32 `json:"transfer_id"`
    Amount          int   `json:"amount"`
    SenderID        int   `json:"sender_id"`
    SenderBalance   int   `json:"sender_balance"`   // post-TX
    ReceiverID      int   `json:"receiver_id"`
    ReceiverBalance int   `json:"receiver_balance"` // post-TX
}
```

#### 2b — Write the balance read model on every transfer

Pipeline the balance update alongside the existing cache invalidation and event publish:

```go
pipe := redisClient.Pipeline()
// 1. Invalidate stale user cache
pipe.Del(ctx, "user_cache:phone:"+res.senderPhone, "user_cache:phone:"+res.receiverPhone)
// 2. Update balance read model (Redis Hash keyed by user ID)
pipe.HSet(ctx, "balance", res.senderID, res.senderBalance)
pipe.HSet(ctx, "balance", res.receiverID, res.receiverBalance)
// 3. Publish real-time event to WebSocket subscribers
eventJSON, _ := json.Marshal(evt)
pipe.Publish(ctx, fmt.Sprintf("notify:%d", res.receiverID), string(eventJSON))
_, _ = pipe.Exec(ctx)
```

The window of inconsistency between the PG commit and the Redis write is the Go pipeline
execution time (<1 ms, same process, same host in all deployment modes).

#### 2c — `account-service` serves balance from the read model

Modify `handleBalance` in `services/account-service/handlers.go` to read from the Redis hash with
a DB fallback for cold starts and Redis restarts:

```go
func handleBalance(bdb bob.DB, rc *goredis.Client, logger *slog.Logger) internnats.Handler {
    return func(ctx context.Context, _ string, _ json.RawMessage, _ map[string]string) (any, error) {
        userID, _ := internnats.UserIDFromContext(ctx)

        // Read model: "balance" Redis Hash, field = userID (string).
        val, err := rc.HGet(ctx, "balance", strconv.Itoa(userID)).Int()
        if errors.Is(err, goredis.Nil) {
            // Cache miss: populate from DB and write back.
            val, err = queryBalanceFromDB(ctx, bdb, userID)
            if err == nil {
                _ = rc.HSet(ctx, "balance", strconv.Itoa(userID), val)
            }
        }
        if err != nil {
            return nil, fmt.Errorf("get balance: %w", err)
        }
        return internnats.Reply(200, map[string]any{"balance": val}), nil
    }
}

func queryBalanceFromDB(ctx context.Context, bdb bob.DB, userID int) (int, error) {
    return bob.One(ctx, bdb,
        psql.Select(sm.Columns("balance"), sm.From("users"),
            sm.Where(psql.Quote("id").EQ(psql.Arg(userID)))),
        scan.SingleColumnMapper[int],
    )
}
```

**Data flow after Tier 2:**

```
transfer command
  → SERIALIZABLE TX commits to PostgreSQL          ← write model (source of truth)
  → pipeline: DEL user_cache, HSET balance, PUBLISH event
  → account-service HGet("balance", userID)        ← read model (Redis)
  → client
```

---

### Tier 3 — NATS JetStream as durable event bus ✅

**Effort: ~1 week.** Replaces the ephemeral Redis `PUBLISH` with a durable, replayable event
stream. Enables `account-service` to rebuild its Redis read model from the event log after a
restart or Redis failure. Fixes Gap 5 (transfer idempotency). Required only if audit-completeness,
compliance, or full event sourcing are needed.
**Status: Implemented. BANKING_EVENTS stream + idempotent publish in transfer-service + durable pull consumer in account-service. Graceful degradation when -js not set.**

All JetStream code in this tier uses the **modern `jetstream` package**
(`github.com/nats-io/nats.go/jetstream`) rather than the legacy `nc.JetStream()` API. The
`jetstream` package provides simpler, predictable interfaces and is the recommended path for new
projects as of `nats.go` v1.28+.

#### 3a — Enable JetStream

JetStream is enabled with a single flag. No protocol change; `nats.go` exposes the modern API
via `jetstream.New(nc)`.

```yaml
# docker-compose.yml — NATS command
command: ["-js"]   # enable JetStream

# or nats-server.conf
jetstream: {
  store_dir: /data
  max_mem: 256m
}
```

#### 3b — Define the `BANKING_EVENTS` stream

Create the stream once at startup from any service that needs it (idempotent — safe to call on
every boot):

```go
import "github.com/nats-io/nats.go/jetstream"

js, err := jetstream.New(nc)
if err != nil {
    return fmt.Errorf("jetstream init: %w", err)
}

_, err = js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
    Name:      "BANKING_EVENTS",
    Subjects:  []string{"banking.events.>"},
    MaxAge:    30 * 24 * time.Hour,
    Storage:   jetstream.FileStorage,
    Retention: jetstream.LimitsPolicy,
    Replicas:  1, // raise to 3 for HA
})
```

Subject hierarchy:

| Subject | Publisher | Consumers |
|---------|-----------|-----------|
| `banking.events.transfer.completed` | `transfer-service` | `account-service` (balance projection), audit processor |
| `banking.events.transfer.>` | `transfer-service` | compliance replay |

#### 3c — `transfer-service` publishes with deduplication

Replace the Redis `PUBLISH` with a JetStream publish. Keep the Redis pipeline for Tier 2 read
model updates — add the durable event alongside:

```go
js, _ := jetstream.New(nc)

// Build the event
evt := iredis.TransferCompleted{ /* ... post-TX fields ... */ }
eventJSON, _ := json.Marshal(evt)

// Tier 2: Redis pipeline (cache invalidation + balance HSET)
pipe := redisClient.Pipeline()
pipe.Del(ctx, "user_cache:phone:"+res.senderPhone, "user_cache:phone:"+res.receiverPhone)
pipe.HSet(ctx, "balance", res.senderID, res.senderBalance)
pipe.HSet(ctx, "balance", res.receiverID, res.receiverBalance)
_, _ = pipe.Exec(ctx)

// Tier 3: durable event + deduplication guard (Gap 5 fix)
// Nats-Msg-Id is the JetStream dedup key — the server discards any message
// with a Msg-Id it has seen within the stream's DuplicateWindow (default 2 min).
_, err = js.PublishMsg(ctx, &nats.Msg{
    Subject: "banking.events.transfer.completed",
    Data:    eventJSON,
    Header: nats.Header{
        "Nats-Msg-Id": []string{strconv.Itoa(int(res.transferID))},
    },
})
```

The `Nats-Msg-Id` header fixes Gap 5: if the HTTP caller retries and the same `transferID` was
already committed and published, JetStream silently discards the duplicate publish. The balance
and notification are not double-applied.

Add `DuplicateWindow` to the stream config when needed:

```go
jetstream.StreamConfig{
    // ...
    Duplicates: 5 * time.Minute, // dedup window; must be > max retry window
}
```

#### 3d — Push/Pull consumer decision

JetStream supports two consumer dispatch modes. **Choose per use-case, not per preference.**

| | Push consumer | Pull consumer |
|---|---|---|
| **Server delivers to** | A fixed delivery subject | Client fetches on demand |
| **Load balancing** | Queue group on delivery subject | Multiple binders on same durable name |
| **Flow control** | `MaxAckPending` limits in-flight acks | Client controls batch size |
| **Replay / rebuild** | `DeliverAll` on restart delivers full history | Same, via `Consume()` |
| **Horizontal scale** | Harder: delivery subject must be shared | Natural: multiple `Consume()` callers |
| **NATS recommendation** | Legacy — kept for migration ease | **Preferred for new projects** |
| **Use in this project** | WebSocket fan-out (real-time, ephemeral) | Balance projection (durable, replayable) |

#### 3e — Pull consumer: balance projection in `account-service`

Use a **durable pull consumer** with `Consume()` for continuous push-like delivery. On restart,
JetStream replays from the last ACKed message — the Redis `balance` hash is rebuilt automatically
without a DB round-trip.

```go
import "github.com/nats-io/nats.go/jetstream"

js, _ := jetstream.New(nc)

// CreateOrUpdateConsumer is idempotent: safe to call on every service restart.
cons, err := js.CreateOrUpdateConsumer(ctx, "BANKING_EVENTS", jetstream.ConsumerConfig{
    Durable:        "account-service-balance",
    FilterSubject:  "banking.events.transfer.completed",
    AckPolicy:      jetstream.AckExplicitPolicy,
    DeliverPolicy:  jetstream.DeliverAllPolicy,   // replay full log on cold start / Redis wipe
    AckWait:        10 * time.Second,
    MaxAckPending:  100,                          // flow control: at most 100 unacked msgs in flight
    MaxDeliver:     5,                            // give up after 5 delivery attempts; emit advisory
    BackOff:        []time.Duration{2*time.Second, 10*time.Second, 30*time.Second},
})
if err != nil {
    return fmt.Errorf("create consumer: %w", err)
}

// Consume() delivers messages continuously, performs pre-buffering.
// Unlike Fetch(), it does not create a new subscription per call.
consCtx, err := cons.Consume(func(msg jetstream.Msg) {
    var evt iredis.TransferCompleted
    if err := json.Unmarshal(msg.Data(), &evt); err != nil {
        logger.Error("js_decode_error", "error", err)
        msg.Nak()
        return
    }
    pipe := rc.Pipeline()
    pipe.HSet(ctx, "balance", evt.SenderID, evt.SenderBalance)
    pipe.HSet(ctx, "balance", evt.ReceiverID, evt.ReceiverBalance)
    if _, err := pipe.Exec(ctx); err != nil {
        logger.Error("redis_pipeline_error", "error", err)
        msg.NakWithDelay(5 * time.Second) // retry after 5 s; does not use BackOff
        return
    }
    msg.Ack()
})
if err != nil {
    return fmt.Errorf("consume: %w", err)
}
defer consCtx.Stop()
```

**Why `DeliverAllPolicy` and not `DeliverNewPolicy`:**
`DeliverNew` only receives messages published after the consumer is created. If Redis is wiped or
`account-service` is redeployed from scratch, the balance hash starts empty and is never rebuilt
from history. `DeliverAll` replays the full stream from sequence 0 on cold start; the durable
offset ensures subsequent restarts resume from the last ACK rather than replaying everything again.

**Why pull (not push) for the balance projection:**
- The projection handler is stateful (writes to Redis) and must process exactly one copy of each
  event — load balancing across multiple `account-service` replicas without double-applying
  balance updates is safe because all replicas bind to the same durable name and JetStream
  distributes each message to exactly one binder.
- `Consume()` handles flow control internally: it pre-buffers up to `MaxAckPending` messages and
  pauses fetching when the consumer falls behind, preventing a slow-consumer disconnect.

#### 3f — Push consumer: real-time WebSocket notifications in `notification-service`

The WebSocket fan-out use-case has different requirements: low latency, per-session delivery, and
no need to replay history on reconnect. An **ephemeral push consumer** is a better fit here than
a durable pull consumer.

```go
js, _ := jetstream.New(nc)

// Ephemeral ordered push consumer — one per connected WebSocket session.
// Ordered consumers handle reconnection and gap detection automatically.
// No Durable name → cleaned up by the server after InactiveThreshold.
cons, err := js.CreateOrUpdateConsumer(ctx, "BANKING_EVENTS", jetstream.ConsumerConfig{
    // No Durable field → ephemeral
    FilterSubject:     fmt.Sprintf("banking.events.transfer.completed"),
    DeliverPolicy:     jetstream.DeliverNewPolicy,   // real-time only; no history replay
    AckPolicy:         jetstream.AckNonePolicy,       // fire-and-forget for WebSocket push
    InactiveThreshold: 30 * time.Second,              // server auto-deletes after WS disconnect
    MemoryStorage:     true,                          // no disk I/O for ephemeral fan-out
})

// Messages() returns an iterator for fine-grained per-message control.
iter, _ := cons.Messages()
go func() {
    defer iter.Stop()
    for {
        msg, err := iter.Next()
        if err != nil {
            return // consumer stopped or context cancelled
        }
        var evt iredis.TransferCompleted
        if json.Unmarshal(msg.Data(), &evt) == nil && evt.ReceiverID == currentUserID {
            wsConn.WriteJSON(evt)
        }
        // AckNone: no acknowledgment required
    }
}()
```

Alternatively, keep the existing Redis pub/sub for WebSocket fan-out (it works well for this
pattern) and use JetStream only for the durable balance projection. See the trade-off table below.

#### 3g — Ordered consumer for audit replay

When an operator or compliance process needs to replay all transfers for a given account, an
**ephemeral ordered pull consumer** is the right tool. It is not durable, not load-balanced, and
delivers messages in strict order:

```go
orderedCons, _ := js.OrderedConsumer(ctx, "BANKING_EVENTS", jetstream.OrderedConsumerConfig{
    FilterSubjects: []string{"banking.events.transfer.completed"},
    DeliverPolicy:  jetstream.DeliverByStartTimePolicy,
    OptStartTime:   &startTime,
})

iter, _ := orderedCons.Messages()
for {
    msg, err := iter.Next()
    if errors.Is(err, jetstream.ErrMsgIteratorClosed) {
        break
    }
    // process audit record
    meta, _ := msg.Metadata()
    if meta.NumPending == 0 {
        break // caught up with stream head
    }
}
iter.Stop()
```

**Data flow after Tier 3:**

```
transfer command
  → SERIALIZABLE TX commits to PostgreSQL           ← write model (source of truth)
  │
  ├── Redis pipeline (Tier 2)
  │     DEL user_cache, HSET balance                ← fast path read model
  │
  └── JetStream BANKING_EVENTS stream               ← durable event log
        ├── account-service pull consumer (durable)
        │     → Redis "balance" HSET on each event  ← projection rebuild on restart
        ├── notification-service push consumer (ephemeral, per session)
        │     → WebSocket push to browser           ← real-time, AckNone
        └── audit pull consumer (ephemeral ordered)
              → compliance replay, point-in-time queries
```

---

## Trade-off summary

| Concern | Current | After Tier 1 | After Tier 2 | After Tier 3 |
|---------|---------|-------------|-------------|-------------|
| Read/write DB contention | Shared pool | Shared pool | Balance served from Redis | No DB reads for balance |
| Balance accuracy in login response | Stale (5 min TTL) | **Fixed** (DEL on transfer) | **Fixed** | **Fixed** |
| Query/command observability | Mixed metrics | Separate subjects | Separate subjects | Separate subjects |
| Event durability | Ephemeral (Redis pub/sub) | Ephemeral | Ephemeral | **Durable (JetStream replay)** |
| Read model rebuild after Redis restart | Cold start from DB | Cold start from DB | Cold start from DB | **Replay from event log** |
| Transfer idempotency | None | None | None | **Nats-Msg-Id deduplication** |
| WebSocket event loss when svc is down | Lost | Lost | Lost | **Durable delivery (push consumer)** |
| Code change volume | — | ~60 lines | ~150 lines | ~400 lines + JetStream config |
| Operational complexity | Low | Low | Low | Moderate (JetStream storage, consumer state) |

---

## Push vs Pull consumer reference

Both modes use the same `BANKING_EVENTS` stream. The choice is per-consumer, not per-stream.

| Signal | Use Push | Use Pull |
|--------|----------|----------|
| Real-time fan-out, fire-and-forget | ✓ | — |
| Per-session ephemeral delivery | ✓ | — |
| Durable projection that must rebuild on restart | — | ✓ |
| Horizontal scaling with load-balanced processing | — | ✓ (same durable name, multiple binders) |
| Batch/audit replay at controlled pace | — | ✓ (Fetch / ordered consumer) |
| Strict in-order audit replay | — | ✓ (OrderedConsumer) |
| Need `Fetch()` for batched processing | — | ✓ |

NATS officially recommends **pull consumers for new projects** where scalability or detailed flow
control is a concern. Push consumers are retained in the `jetstream` package primarily to ease
migration from the legacy `nats` package API.

---

## Recommendation

**Tier 1b now — always.** The `user_cache` balance stale bug is active. Fixing it requires only adding `senderPhone`/`receiverPhone` to `transferResult` and pipelining a `DEL` alongside the existing `PUBLISH`. Cost: ~20 lines.

**Tier 1a (subject rename) — defer or skip.** Renaming `banking.*.requests` to `.commands`/`.queries` pays off in observability, but Phase 6b (action-level subjects — `banking.transfer.send`, etc.) produces a strictly more granular result and supersedes this split entirely. **If Phase 6 is on the roadmap, skip Tier 1a** and route Tier 1b directly into Tier 2 as a single PR. If Phase 6 is not planned, Tier 1a is still a worthwhile one-day change.

**Tier 1b + Tier 2 together now.** Tier 2 absorbs the Tier 1b cache fix — the pipeline that writes `HSET balance` also does `DEL user_cache`. Doing both in one PR eliminates the active bug and removes the only DB read on the hot `balance` path with zero new infrastructure. Redis is already deployed.

**Tier 3 only if needed.** JetStream is the right answer for compliance audit trails, event replay after Redis failure, idempotent transfer deduplication, or full event sourcing. For a demo or low-traffic deployment the operational overhead — JetStream storage, consumer offset tracking, delivery guarantees — exceeds the benefit. The `amqp-to-nats-migration.md` "Two-tier transport" section shows both subject-naming paths (Tier 1a vs Phase 6b) and where JetStream events (`banking.events.*`) fit into each.

---

## Files affected

### Tier 1

Tier 1 has two independent parts. **Tier 1b is always required.** Tier 1a is optional — see Recommendation above.

#### Tier 1b — cache fix ✅ done

| File | Change | Status |
|------|--------|--------|
| `services/transfer-service/handlers.go` | `transferResult` extended: `senderPhone`, `receiverPhone`, `senderID`, `senderBalance`, `receiverBalance`; `runTransferTx` populates post-TX balances in Go; `handleTransfer` calls `iredis.PublishTransferCompleted` | ✅ |
| `internal/redis/redis.go` | `PublishTransferCompleted(ctx, c, evt, senderPhone, receiverPhone)` — 4-command pipeline in one Redis round-trip | ✅ |
| `internal/db/db.go` | No change | ✅ |

#### Tier 1a — subject rename (superseded by Phase 6b)

Phase 6b per-action subjects (`banking.auth.login`, `banking.account.balance`, etc.) are a strict
superset of the `.commands`/`.queries` split. **Tier 1a is skipped as planned.**

### Tier 2 (additive to Tier 1) ✅ done

| File | Change | Status |
|------|--------|--------|
| `internal/redis/redis.go` | `TransferCompleted` struct; `SetBalance(ctx, c, userID, balance)`; `GetBalance(ctx, c, userID) (int, bool, error)` — goredis.Nil absorbed | ✅ |
| `services/transfer-service/handlers.go` | `iredis.PublishTransferCompleted` pipeline (DEL + HSET×2 + PUBLISH) — single round-trip | ✅ |
| `services/account-service/handlers.go` | `handleBalance`: `iredis.GetBalance` → DB fallback → `iredis.SetBalance` warm-up; `queryBalanceFromDB` helper | ✅ |
| `services/account-service/main.go` | `handleBalance` receives `d.RedisClient`; `requireSession` applied | ✅ |

### Tier 3 (additive to Tier 2) ✅ done

| File | Change | Status |
|------|--------|--------|
| `docker-compose.yml` | `command: ["-js", "--store_dir", "/data", "--http_port", "8222"]`; `natsdata` volume | ✅ |
| `helm/charts/nats/values.yaml` | `jetstream.enabled`, `storageDir`, `storage.size`; `readOnlyRootFilesystem: false` | ✅ |
| `helm/templates/nats.yaml` | Conditional `-js` args + volumeMount + PVC when `jetstream.enabled` | ✅ |
| `internal/go.mod` | No change — `jetstream` package ships inside `nats.go v1.52.0` | ✅ |
| `internal/nats/jetstream.go` | **New file** — `InitStream`, `PublishTransferEvent`, `NewBalanceConsumer`, `StreamName`, `SubjectTransferCompleted`, `ConsumerBalanceProjection` constants | ✅ |
| `internal/nats/consumer.go` | `WithConn(nc)` option; `Connect(url, name, logger, reconnectMetric)` exported helper | ✅ |
| `services/transfer-service/main.go` | `Connect` once → shared `nc`; `InitStream` + graceful warn on JS unavailable; `WithConn(nc)` passed to Consumer | ✅ |
| `services/transfer-service/handlers.go` | `handleTransfer` takes `js jetstream.JetStream`; Tier 3 `PublishTransferEvent` called after Tier 2 pipeline; `js==nil` guarded | ✅ |
| `services/account-service/main.go` | `Connect` once → shared `nc`; `InitStream`; `runBalanceProjection` goroutine (`DeliverAllPolicy`, `MaxAckPending=100`, `NakWithDelay`); graceful warn on JS unavailable | ✅ |
| `services/notification-service/main.go` | Unchanged — Redis pub/sub retained for WebSocket fan-out (correct choice; see §3f) | ✅ |
| `internal/redis/redis.go` | No change beyond Tier 2 | ✅ |

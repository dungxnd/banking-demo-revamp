# Architecture Decision Log

Decisions that shaped this codebase, in the order they were made. Each entry explains what was
chosen, what the realistic alternatives were, and why the chosen path was taken. The goal is to
make every non-obvious choice reproducible: a new contributor reading this should be able to
trace any structural characteristic of the code back to a documented reason.

---

## Table of contents

1. [Go rewrite — why Go over Python](#1-go-rewrite--why-go-over-python)
2. [DB layer — bob over sqlc or raw pgx](#2-db-layer--bob-over-sqlc-or-raw-pgx)
3. [Go workspace (go.work) over a monorepo root module](#3-go-workspace-gowork-over-a-monorepo-root-module)
4. [Service boundary design — why four separate modules](#4-service-boundary-design--why-four-separate-modules)
5. [Redis type alias — type Client = goredis.Client](#5-redis-type-alias--type-client--goredisClient)
6. [AMQP → NATS — why replace RabbitMQ](#6-amqp--nats--why-replace-rabbitmq)
7. [Core NATS for RPC, not JetStream](#7-core-nats-for-rpc-not-jetstream)
8. [nats/micro framework adoption (Phase 6a)](#8-natsmicro-framework-adoption-phase-6a)
9. [Per-action subjects over per-service subjects (Phase 6b)](#9-per-action-subjects-over-per-service-subjects-phase-6b)
10. [CQRS Tier 1a skipped — Phase 6b subsumes it](#10-cqrs-tier-1a-skipped--phase-6b-subsumes-it)
11. [CQRS Tier 1b — user_cache invalidation on transfer commit](#11-cqrs-tier-1b--user_cache-invalidation-on-transfer-commit)
12. [CQRS Tier 2 — Redis balance hash as read model](#12-cqrs-tier-2--redis-balance-hash-as-read-model)
13. [Post-TX balances computed in Go, not from a second DB query](#13-post-tx-balances-computed-in-go-not-from-a-second-db-query)
14. [Tier 1b and Tier 2 in one PR, not two](#14-tier-1b-and-tier-2-in-one-pr-not-two)
15. [CQRS Tier 3 — JetStream BANKING_EVENTS stream](#15-cqrs-tier-3--jetstream-banking_events-stream)
16. [Pull consumer over push consumer for balance projection](#16-pull-consumer-over-push-consumer-for-balance-projection)
17. [Redis pub/sub retained for WebSocket fan-out](#17-redis-pubsub-retained-for-websocket-fan-out)
18. [Graceful degradation when JetStream is absent](#18-graceful-degradation-when-jetstream-is-absent)
19. [Shared NATS connection — one nc per service process](#19-shared-nats-connection--one-nc-per-service-process)
20. [Nats-Trace-Dest sampled header — 1% default, env-tunable](#20-nats-trace-dest-sampled-header--1-default-env-tunable)
21. [PublishTransferCompleted owns all Redis key strings](#21-publishtransfercompleted-owns-all-redis-key-strings)
22. [Error handling after transfer commit — non-fatal, log only](#22-error-handling-after-transfer-commit--non-fatal-log-only)
23. [SELECT FOR UPDATE with deterministic lock ordering](#23-select-for-update-with-deterministic-lock-ordering)
24. [slog over zap/zerolog/logrus](#24-slog-over-zapzerolog-logrus)
25. [TTL values via sync.OnceValue, not init()](#25-ttl-values-via-synconcevalue-not-init)
26. [MaskAmount using HMAC, not redaction or rounding](#26-maskamount-using-hmac-not-redaction-or-rounding)
27. [tracing.Init shutdown — 5-second baked-in timeout](#27-tracinginit-shutdown--5-second-baked-in-timeout)
28. [Runner — three-goroutine errgroup lifecycle](#28-runner--three-goroutine-errgroup-lifecycle)

---

## 1. Go rewrite — why Go over Python

**Chosen:** rewrite all four consumer services and `internal/` in Go.

**Alternatives:**
- Keep Python FastAPI services, only update messaging layer.
- Rewrite in TypeScript/Node (same team skillset as frontend).
- Rewrite in Rust.

**Reasoning:**

The Python services worked, but had several invisible costs that only become visible at scale or
during incident response:

- **aio_pika reconnect**: the Python AMQP consumer used `connect_robust`, which hides reconnection
  behind a library magic; there was no explicit reconnect strategy, backoff, or jitter. Under a
  mass restart (deploy or crash), all services would reconnect simultaneously, spiking RabbitMQ
  connections. Go's explicit `nats.ReconnectJitter` is a conscious line of code, not an implicit
  library behaviour.
- **Implicit middleware**: `instrument_fastapi` and SQLAlchemy session management happened
  transparently. The Python code was short because it delegated everything hard to `common/`
  helpers. Those helpers existed — they just weren't visible per-service, making auditing harder.
- **Type safety at boundaries**: JSON deserialization in Python is unchecked at the struct level.
  The Go `json.Unmarshal` into typed structs, combined with sentinel errors like
  `errInsufficientFunds`, makes the transfer handler's error paths fully enumerable.
- **Goroutine model for WebSocket**: `notification-service` runs a NATS consumer and an HTTP/WebSocket
  server concurrently. In Python this required asyncio task management. In Go it is three lines of
  `errgroup` with a single shared context cancellation path.
- **Single binary deployment**: each Go service produces a static binary. No interpreter, no
  venv, no `requirements.txt` mismatch. The Dockerfile final stage is `FROM alpine:3.23` with the
  binary copied in. Python Dockerfiles are significantly more complex and slower to build.

TypeScript was rejected because it would fragment the backend stack (the producer was already in Go,
the `internal/` library would need to be duplicated in two languages) and does not offer Go's
goroutine concurrency model for the WebSocket use-case.

---

## 2. DB layer — bob over sqlc or raw pgx

**Chosen:** [stephenafamo/bob](https://github.com/stephenafamo/bob) for all database queries.

**Alternatives:**
- `sqlc` — compile-time SQL-to-Go codegen.
- Raw `pgx` — hand-written query functions.
- `gorm` — ORM with reflection-based query building.

**Reasoning:**

`sqlc` was the first candidate. It is excellent for fixed queries but cannot build dynamic `WHERE`
clauses at runtime. The admin `users` endpoint requires optional ILIKE filters across `username`,
`phone`, and `account_number` simultaneously, with the filter being absent entirely on unfiltered
requests. This is not expressible in a single static SQL file: it requires conditional query
composition. `sqlc` rejects parameterised conditional WHERE — you would need multiple query files
and a Go-level dispatch switch. That dispatch would be hand-written anyway, erasing the main
benefit of code generation.

`gorm` was rejected because it uses reflection to map struct tags to SQL, making query behaviour
invisible until runtime. It also generates `SELECT *` by default, which is fragile when columns
are added.

Raw `pgx` is viable but requires hand-writing `rows.Scan()` for every query, which is error-prone
(column order sensitivity) and repetitive.

`bob` solves all three problems: composable query mods (`sm.Where(...)` appended at runtime),
typed column references (`psql.Quote("id")` rather than bare strings), `SELECT FOR UPDATE` as a
first-class mod (`sm.ForUpdate()`), and `bobgen-psql` for typed row structs from the live schema.
The dynamic admin search is 10 lines; `SELECT FOR UPDATE` with deterministic lock ordering is
explicit and readable.

---

## 3. Go workspace (go.work) over a monorepo root module

**Chosen:** `go.work` with six separate modules (`internal/`, `producer/`, and four services).

**Alternatives:**
- Single root module with all packages inside.
- `replace` directives in each `go.mod` without `go.work`.

**Reasoning:**

A single root module would mean all services share a `go.mod` and produce a single build graph.
This creates transitive dependency coupling: adding `coder/websocket` for `notification-service`
pulls it into every service's dependency tree, even though only one binary ever uses it.

`go.work` gives independent dependency trees per module while sharing source via the workspace
overlay during development. Services can be built independently (`go build ./...` from
`services/auth-service/`) with the workspace's `replace`-equivalent automatically applied. This
also means each service module has a minimal, correct `go.sum` — not one bloated shared file.

The `replace` directive approach without `go.work` was used before Go 1.18 but is now the
anti-pattern; the tooling (gopls, `go mod tidy`, `go work sync`) works better with `go.work`.

---

## 4. Service boundary design — why four separate modules

**Chosen:** one Go module per service, with `internal/` as a separate shared module.

**Alternatives:**
- All services in a single Go binary with a router.
- Two modules: `internal/` and a single `services/` module.

**Reasoning:**

The services have different scaling profiles: `account-service` (read queries, admin) and
`notification-service` (WebSocket connections) scale independently of `transfer-service`
(SERIALIZABLE transactions). Having separate binaries means each can be scaled, deployed, and
restarted independently via `docker-compose up --scale account-service=3` without touching the
others.

`internal/` is separate because it has no `main` function and must not import any service-specific
code. Keeping it as a separate module enforces this at the `go build` level.

---

## 5. Redis type alias — `type Client = goredis.Client`

**Chosen:** `type Client = goredis.Client` in `internal/redis/redis.go`; services import
`iredis "banking-demo/internal/redis"` and type their parameters as `*iredis.Client`.

**Alternatives:**
- Services import `go-redis` directly and use `*goredis.Client`.
- Define an interface (`iredis.Clienter`) that wraps the methods used.

**Reasoning:**

If services import `go-redis` directly, upgrading go-redis (a transitive dep of `internal/`) must
be coordinated across every service module simultaneously. With the alias, only `internal/go.mod`
contains the go-redis import; services never see it in their own `go.mod`.

An interface was rejected because `go-redis` does not publish a `Doer` interface that matches all
its method signatures cleanly. Creating a custom interface would require either wrapping every
method used (dozens of methods for pipeline, pub/sub, hash ops) or using `any` parameters, both
of which are worse than the alias.

The type alias (`=`) is the correct Go mechanism: it is the same underlying type, so callers can
still pass a `*goredis.Client` directly if needed. A defined type (`type Client goredis.Client`)
would break method promotion.

---

## 6. AMQP → NATS — why replace RabbitMQ

**Chosen:** replace RabbitMQ (`amqp091-go`) with NATS (`nats.go v1.52.0`).

**Alternatives:**
- Keep RabbitMQ, refactor the consumer framework only.
- Switch to Kafka for both RPC and events.

**Reasoning:**

The AMQP RPC pattern required four things per request: (1) declare a per-producer exclusive
auto-delete reply queue once, (2) publish to the service queue with `reply_to` and
`correlation_id` headers, (3) maintain a `sync.Map` of pending futures keyed by `correlation_id`,
and (4) on consumer reply, look up the future and deliver the result. The Go producer's `rpc.go`
was ~200 lines managing this machinery.

NATS request/reply replaces all four steps with one: `nc.RequestMsgWithContext(ctx, msg)`. The
server creates an ephemeral `_INBOX.*` subject per request, delivers the reply directly to the
waiting goroutine, and discards the inbox when done. There is no queue to declare, no correlation
ID to track, and no reply map to manage. The new `rpc.go` is ~80 lines.

NATS also eliminates the topology declaration problem on reconnect: with AMQP, a reconnect
requires re-declaring exchanges, queues, and bindings before consuming can resume. With NATS,
reconnect is handled by the library with no topology to restore.

Kafka was considered only briefly. Kafka is a log storage system used as a message bus. Its
consumer model (partition assignment, offset management, consumer groups) is designed for ordered,
durable streams. For synchronous RPC where the producer blocks waiting for a reply, Kafka's
architecture is strictly worse: you cannot do request/reply efficiently, the operational overhead
(ZooKeeper or KRaft, partition rebalancing, retention policy management) is high, and the Go
client (`confluent-kafka-go`, `segmentio/kafka-go`) is more complex than `nats.go`.

---

## 7. Core NATS for RPC, not JetStream

**Chosen:** Core NATS `RequestMsgWithContext` for the RPC transport between producer and services.

**Alternatives:**
- JetStream streams for RPC (producer publishes to a stream, consumer replies).
- JetStream for commands only (transfers), Core NATS for queries.

**Reasoning:**

The NATS documentation states explicitly:

> *"Service patterns where there is a tightly coupled request-reply — a request is made, and the
> application handles error cases upon timeout. Relying on a messaging system to resend here is
> considered an anti-pattern."*

Three specific properties of this architecture confirm Core NATS is correct:

1. **A received reply is a stronger guarantee than a broker ack.** The producer gets a reply only
   after the consumer has processed the message and called `req.Respond()`. JetStream publisher
   acks confirm broker receipt, not processing — a weaker guarantee for the same cost.

2. **JetStream cannot serve the reply half of RPC.** Reply subjects (`_INBOX.*`) are ephemeral
   Core NATS inboxes by definition; JetStream streams cannot capture them.

3. **`ErrNoResponders` is better UX than durable queuing.** If all consumer instances are down,
   Core NATS returns the error immediately → HTTP 503. With JetStream, the request is durably held
   and the HTTP caller hangs until the 60-second timeout.

JetStream is used for the post-commit event bus (`BANKING_EVENTS` stream) where its guarantees
genuinely apply — see [decision 15](#15-cqrs-tier-3--jetstream-banking_events-stream).

---

## 8. nats/micro framework adoption (Phase 6a)

**Chosen:** replace `QueueSubscribe` with `nats/micro` (`micro.AddService` + `svc.AddEndpoint`).

**Alternatives:**
- Keep `QueueSubscribe` with a custom dispatch switch.
- Use a third-party micro-framework on top of NATS.

**Reasoning:**

The `nats/micro` package ships inside `nats.go` (no new dependency). It provides:

- **Service discovery**: `nats micro ls` lists all running service instances by name and version.
- **Per-action stats**: `nats micro stats <name>` shows request count, error count, last error, and
  average latency per endpoint — independently for `login`, `balance`, `transfer`, etc.
- **Built-in health ping**: `$SRV.PING.<name>` responds without any handler code.
- **Structured service metadata**: `$SRV.INFO.<name>` exposes all endpoint subjects and versions.

These replace the manual `health.NATSHandler` registration that every service previously needed.
More importantly, `$SRV.STATS` provides the per-action observability that was previously only
available via Prometheus metrics — and it works even before the Prometheus stack is wired up (e.g.
in local `nats-server` testing).

---

## 9. Per-action subjects over per-service subjects (Phase 6b)

**Chosen:** one NATS subject per action (`banking.account.balance`, `banking.transfer.transfer`,
etc.) rather than one subject per service (`banking.account.requests`).

**Alternatives:**
- Keep `banking.*.requests` with action dispatch in the consumer body.
- Service-level split into `.commands` and `.queries` (CQRS Tier 1a).

**Reasoning:**

Per-service subjects route all actions for a service through one queue group. This means load
balancing, backpressure, and metrics are aggregated across all actions. A slow admin query
(paginated user list with ILIKE) cannot be distinguished from a fast balance lookup at the NATS
level.

Per-action subjects give independent load balancing and backpressure per action. A slow admin
endpoint does not starve fast user-facing endpoints. `nats micro stats account-service` shows
separate request counts and average latency for `me`, `balance`, `lookup`, `stats`, etc.

The `.commands`/`.queries` split (Tier 1a) was the intermediate option — it separates read from
write but aggregates all commands together and all queries together. Per-action subjects are
strictly more granular: action names already encode the command-vs-query distinction
(`transfer` vs `balance`), so the `.commands`/`.queries` split adds naming complexity without
adding observability that per-action subjects don't already provide.

The producer's `subjectFromPath` is an exhaustive `switch` with no default fallback to a service
subject. Unknown paths return `""` → HTTP 404. This is intentional: routing by convention
(prefix match) would silently route new paths to wrong services.

---

## 10. CQRS Tier 1a skipped — Phase 6b subsumes it

**Chosen:** skip the `.commands`/`.queries` subject split entirely.

**Reasoning:**

Tier 1a would rename `banking.auth.requests` to `banking.auth.commands` and `banking.auth.queries`.
Phase 6b produces `banking.auth.login` and `banking.auth.register` — both more specific and
semantically equivalent. `banking.auth.login` is obviously a command; `banking.account.balance` is
obviously a query. The `.commands`/`.queries` suffix adds characters without adding information.

If Tier 1a were done before Phase 6b, it would need to be undone again. Two migrations for the
same goal, with the second one being a strict improvement over the first.

---

## 11. CQRS Tier 1b — user_cache invalidation on transfer commit

**Chosen:** DEL `user_cache:phone:{senderPhone}` and `user_cache:phone:{receiverPhone}` in the
post-commit pipeline.

**Context — what the bug was:**

`auth-service` writes `CachedUser` (including `Balance`) to `user_cache:phone:{phone}` on login.
`transfer-service` updates `users.balance` in PostgreSQL but never touches the cache. On the next
login (within the 5-minute TTL), the user sees their pre-transfer balance. This is not a read
isolation issue — it is a stale cache that survives the transaction.

**Alternatives:**
- Invalidate only the username key (phone is the primary login field).
- Write the updated balance into the cache rather than deleting.
- Accept the 5-minute staleness as documented behaviour.

**Reasoning:**

Deleting both keys (`phone` and `phone` — username keys are not invalidated here because the
phone key is the authoritative login path for transfers) is simpler and correct:
- On the next login, the cache is cold and the DB row is fresh.
- If we wrote the new balance into `CachedUser`, we'd need to reconstruct the full `CachedUser`
  struct in `transfer-service`, which doesn't have access to `PasswordHash`, `AccountNumber`, etc.
  without an extra DB query. DEL is always safe.
- Accepting staleness was rejected because the login response `balance` field is displayed in the
  UI immediately after a transfer — showing a pre-transfer balance is a visible correctness bug.

The 5-minute TTL is not a mitigation; it is the staleness window. The fix eliminates the window.

---

## 12. CQRS Tier 2 — Redis balance hash as read model

**Chosen:** Redis Hash `balance` (field = userID string → value = balance integer) as the primary
read source for `handleBalance`.

**Alternatives:**
- PostgreSQL read replica — separate `DATABASE_URL_READONLY` for queries.
- Materialized view in PostgreSQL.
- Full Redis JSON blob per user (update the whole `CachedUser`).

**Reasoning:**

A PostgreSQL read replica would solve DB contention but requires new infrastructure (replication
slot, standby instance) and changes the connection pool configuration of two services.

A materialized view adds operational overhead (refresh scheduling, staleness between refreshes)
and doesn't eliminate the DB round-trip — it just moves it to a different table.

Updating the full `CachedUser` blob was considered but rejected (see decision 11 above — transfer-
service would need to fetch fields it doesn't own).

The Redis Hash is already deployed. `HSET balance {userID} {balance}` is O(1) and colocated with
the cache DEL commands that were already in the pipeline. No new infrastructure. The balance field
is the one field in `CachedUser` that changes on every transfer and is meaningless after the fact —
keeping it in the user cache is strictly worse than keeping it in a purpose-built hash.

The `balance` hash has no TTL. It is written on every transfer and warm-filled on first balance
request (DB fallback). The only way it becomes stale is if transfer-service's post-commit pipeline
fails — in which case the DB fallback in `handleBalance` serves the correct value and re-warms the
hash.

---

## 13. Post-TX balances computed in Go, not from a second DB query

**Chosen:** compute `senderBalance = senderPreTX - amount` and
`receiverBalance = receiverPreTX + amount` in Go after the transaction commits.

**Alternatives:**
- Add `RETURNING balance` to the `UPDATE` statements inside the transaction.
- Issue a separate `SELECT balance` after the `UPDATE` (still inside the transaction).

**Reasoning:**

The `UPDATE users SET balance = balance - amount WHERE id = $1` statement does not return the
updated value unless `RETURNING balance` is added. Adding `RETURNING` requires changing the bob
`um.Update` call from `bob.Exec` to `bob.One` and scanning the result — more code, and it ties
the post-TX balance to the DB query path rather than pure logic.

The Go computation is provably correct: the `lockBothUsers` SELECT FOR UPDATE reads the pre-TX
values under the same transaction isolation level that then applies the UPDATE. The UPDATE applies
exactly `amount`. Therefore `postTX = preTX ∓ amount` with no race condition possible — the row
lock is held for the duration.

This is not an approximation. It is the exact arithmetic applied by the SQL UPDATE, computed in Go
from the same pre-TX values that the UPDATE was based on.

---

## 14. Tier 1b and Tier 2 in one PR, not two

**Chosen:** implement Tier 1b (cache DEL) and Tier 2 (balance HSET) in a single changeset.

**Reasoning:**

Tier 1b fixes a stale balance bug. Tier 2 adds a balance read model. The overlap is the
post-commit pipeline: both operations run in the same Redis `Pipeline()` call. If Tier 1b were
done alone, the pipeline would contain `DEL` + `PUBLISH`. Tier 2 then adds `HSET` to that
pipeline — touching the same function in the same file.

Doing them separately means two code changes to `handleTransfer` at the same location, two code
reviews of overlapping context, and a short window where the balance cache is invalidated on
transfer (Tier 1b) but the read model doesn't exist yet (pre-Tier 2), causing every `handleBalance`
request to fall through to the DB.

The combined PR eliminates the intermediate broken state and reduces the total diff by ~30%.

---

## 15. CQRS Tier 3 — JetStream BANKING_EVENTS stream

**Chosen:** NATS JetStream `BANKING_EVENTS` stream with `banking.events.>` subject hierarchy.

**Context — what problem this solves:**

Without JetStream:
- If Redis is wiped (restart, OOM eviction), the `balance` hash is lost. `account-service` falls
  back to the DB on every request until transfers happen again and rewrite the hash — a temporary
  but complete loss of the read model.
- If `notification-service` is down during a transfer, the `PUBLISH notify:{id}` is fire-and-
  forget and the event is lost permanently.
- A client retry can double-commit a transfer (`INSERT INTO transfers` is not idempotent at the
  application level).

**Reasoning:**

JetStream's `DeliverAllPolicy` on a durable pull consumer means `account-service` can replay the
full event log from sequence 0 after a Redis wipe and rebuild the `balance` hash without a
single DB round-trip. The durable offset ensures subsequent restarts resume from the last ACK.

`Nats-Msg-Id: {transferID}` deduplicated within a 5-minute window means a client retry that
produces the same transfer ID (already committed to PostgreSQL) results in a silently discarded
JetStream publish. The balance and notification are not double-applied.

The stream uses `FileStorage` so events survive NATS restarts. The `natsdata` Docker volume and
Helm PVC persist the stream state across container/pod restarts.

---

## 16. Pull consumer over push consumer for balance projection

**Chosen:** durable pull consumer (`Consume()` API) for `account-service-balance`.

**Alternatives:**
- Push consumer on a delivery subject.

**Reasoning:**

Pull consumers with `Consume()` are **NATS's recommended approach for new projects**.

For the balance projection specifically:

- **Load balancing across replicas**: multiple `account-service` replicas bind to the same
  durable consumer name. JetStream distributes each message to exactly one binder — no
  double-application of balance updates. Push consumers require a shared delivery subject to
  achieve this, which is harder to configure correctly.

- **Flow control**: `Consume()` pre-buffers up to `MaxAckPending` (100) messages and pauses
  fetching when the consumer falls behind. This prevents a slow-consumer disconnect during a
  Redis hiccup. Push consumers rely on `MaxAckPending` too but the server drives delivery, making
  it harder to rate-limit from the client side.

- **`DeliverAllPolicy` for cold-start replay**: on a fresh deployment or Redis wipe, the consumer
  replays from sequence 0. With `Consume()`, this happens automatically on the next `cons.Consume()`
  call — no special startup code needed.

---

## 17. Redis pub/sub retained for WebSocket fan-out

**Chosen:** keep `redis.SubscribeNotify` in `notification-service/ws.go`; do not replace with a
JetStream push consumer.

**Alternatives:**
- Per-session ephemeral JetStream push consumer with `AckNonePolicy` + `DeliverNewPolicy`.

**Reasoning:**

The WebSocket fan-out case has three properties that favour Redis pub/sub:

1. **No history replay needed**: the browser's WebSocket is a live connection. When it connects,
   the user already has their notification history from the NATS `notifications` endpoint. There
   is no reason to replay past events on connect.

2. **Ephemeral per-session delivery**: Redis `Subscribe` creates a pub/sub subscription scoped
   to the WebSocket goroutine's context. When the connection closes, `unsub()` is called and the
   subscription is cleaned up immediately. A JetStream ephemeral consumer requires an
   `InactiveThreshold` timer — there is always a window between disconnect and server cleanup.

3. **Already deployed and working**: Redis is already required by all services. Adding a JetStream
   consumer to notification-service solely for WebSocket fan-out adds operational complexity
   (the service must now handle stream init, consumer creation, context lifecycle) for no
   functional gain over the existing pub/sub.

The `cqrs-plan.md §3f` documents the JetStream push consumer approach as a valid alternative for
future consideration (e.g. if Redis is removed from the stack), but it is not the right default.

---

## 18. Graceful degradation when JetStream is absent

**Chosen:** both `transfer-service` and `account-service` log a `WARN` and continue when
`InitStream` fails (NATS server has no `-js` flag).

**Alternatives:**
- Fatal error — refuse to start if JetStream is unavailable.
- Panic with a clear message.

**Reasoning:**

The system is useful without JetStream. CQRS Tier 2 (Redis balance hash + cache invalidation) is
independent of Tier 3 and provides the primary benefit (no DB round-trips for balance, no stale
cache). Tier 3 adds durability for the read model and deduplication — features that improve
resilience but are not required for correctness.

Making Tier 3 optional at runtime means:
- The same Docker image can be used with a Core NATS deployment (e.g. a developer laptop with
  `docker run nats:2-alpine`) and a JetStream deployment (production with `nats:2-alpine -js`).
- A partial infrastructure failure (NATS disk full, preventing stream creation) does not take
  down transfers.
- The service logs make it clear what is and isn't active (`jetstream_unavailable_*` WARN lines).

---

## 19. Shared NATS connection — one nc per service process

**Chosen:** `transfer-service` and `account-service` call `internnats.Connect()` once at startup
and pass the resulting `*nats.Conn` to both the `Consumer` (via `WithConn(nc)`) and `InitStream`.

**Alternatives:**
- Separate connections for RPC consumer and JetStream.
- Let the Consumer create its own connection (previous default behaviour).

**Reasoning:**

A `*nats.Conn` is a multiplexed TCP connection. NATS supports multiple subscriptions, publishers,
and JetStream contexts on a single connection. Creating two connections from the same process to
the same NATS server uses twice the file descriptors and twice the heartbeat traffic, for no
benefit.

The previous default (`Consumer.Run` creating its own connection) was fine when only the
consumer needed NATS. Now that JetStream also needs a `*nats.Conn`, the connection must be
created before both the consumer and the JetStream context are initialized. `WithConn(nc)` injects
the pre-created connection; when this option is present, `Consumer.Run` does not `defer nc.Drain()`
because it does not own the connection lifetime.

The `Connect()` function is extracted and exported so all services use identical connection options
(retry, jitter, ping interval, error handlers) without duplicating the option list.

---

## 20. Nats-Trace-Dest sampled header — 1% default, env-tunable

**Chosen:** add `Nats-Trace-Dest: banking.trace.rpc.<subject>` to 1% of RPC requests by default,
with `NATS_TRACE_SAMPLE_RATE` env var override.

**Alternatives:**
- Trace all requests (100%).
- Trace none (remove the feature).
- Fixed random seed for deterministic testing.

**Reasoning:**

NATS 2.11 server-level distributed tracing uses this header to record per-hop latency at the
broker layer — independent of OTel spans, which cover the application layer. At 100% sampling this
doubles the NATS message volume (each traced message produces a trace event on the destination
subject). At 1% the overhead is negligible in production.

The header is transparent to consumers — the NATS 2.11 server strips it before message delivery.
Setting `NATS_TRACE_SAMPLE_RATE=1` in staging or during an incident gives full visibility without
a code deploy. Setting it to `0` disables entirely for environments where the NATS version is < 2.11.

`math/rand/v2` is used (available since Go 1.22); no global state, concurrent-safe.

---

## 21. PublishTransferCompleted owns all Redis key strings

**Chosen:** all Redis key names (`user_cache:phone:*`, `balance`, `notify:*`) live only in
`internal/redis/redis.go`. `transfer-service` calls `iredis.PublishTransferCompleted(ctx, rc, evt,
senderPhone, receiverPhone)` with domain-level arguments.

**Alternatives:**
- Transfer-service constructs the key strings itself.
- Export key-name constants from `internal/redis`.

**Reasoning:**

Key naming is a Redis implementation detail, not a business domain concept. If `user_cache:phone:`
is ever renamed (e.g. to `ucache:p:` for compactness), the change must happen in exactly one place
and all callers are automatically correct. If transfer-service constructs `"user_cache:phone:" +
phone` directly, it is a coupling that requires a grep to find all usages and verify consistency.

Exporting key-name constants is better than raw string literals in callers, but still exposes the
naming format. Hiding it behind a typed function (`PublishTransferCompleted`) means callers work
entirely in domain terms (`senderPhone`, `receiverPhone`) and the Redis implementation can be
replaced without modifying any service.

This is the same principle applied to all redis helpers: `SubscribeNotify(ctx, rc, userID)` not
`Subscribe(ctx, rc, "notify:" + strconv.Itoa(userID))`.

---

## 22. Error handling after transfer commit — non-fatal, log only

**Chosen:** post-commit pipeline failures (Redis, JetStream) are logged as `WARN` and the
transfer HTTP response is still `200` with `transfer_id`.

**Alternatives:**
- Return `500` if the Redis pipeline fails.
- Retry the pipeline synchronously before responding.

**Reasoning:**

The transfer is committed to PostgreSQL. The write model (source of truth) is correct. The
receiver has their money. Returning `500` to the client at this point would cause the client to
retry — potentially submitting a second transfer. This is worse than the Redis/JetStream failure.

The Redis pipeline failure means:
- The `user_cache` is not invalidated — next login shows stale balance for up to 5 minutes. A
  known, bounded, self-correcting staleness.
- The `balance` hash is not updated — next `handleBalance` falls back to DB and re-warms. A brief
  DB round-trip, not a correctness issue.
- The WebSocket `PUBLISH` is not sent — the receiver's browser doesn't get a real-time push. A UX
  degradation, not a correctness issue.

All of these are observable via the `post_commit_redis_pipeline_failed` WARN log. The alternative
(returning 500) creates a correctness issue (double transfer on retry) to avoid a UX degradation
(no real-time push). That trade-off is clearly wrong.

---

## 23. SELECT FOR UPDATE with deterministic lock ordering

**Chosen:** lock the user with the lower ID first, regardless of who is sender and receiver.

**Context — why this matters:**

If Alice (ID=1) transfers to Bob (ID=2) at the same time Bob transfers to Alice, two transactions
will attempt to lock both rows. Without deterministic ordering:
- TX1 locks Alice, waits for Bob.
- TX2 locks Bob, waits for Alice.
- Deadlock: PostgreSQL detects and aborts one transaction.

With deterministic ordering (lower ID first):
- Both transactions attempt to lock ID=1 (Alice) first.
- TX1 acquires Alice's lock, then Bob's.
- TX2 waits for Alice's lock, then acquires it, then acquires Bob's.
- No deadlock — only serialization delay.

**Implementation:**

`lockBothUsers` locks `min(senderID, receiverID)` first, then `max(...)`. After both locks are
acquired, the result is re-assigned to `sender`/`receiver` based on which ID matches `senderID`.
The lock order is not the business logic order; they are independent.

This is explicitly documented in `handlers.go` and in `transfer-service/README.md` because it is
the kind of correctness requirement that is easy to break when "simplifying" the lock query.

---

## 24. slog over zap/zerolog/logrus

**Chosen:** `log/slog` (Go 1.21 stdlib).

**Alternatives:**
- `uber-go/zap` — structured, high-performance.
- `rs/zerolog` — zero-allocation JSON.
- `sirupsen/logrus` — original structured logger.

**Reasoning:**

`slog` is the standard library's structured logging package. Using it means:
- Zero additional dependencies.
- Any library that emits `slog` records integrates natively (Go 1.21+).
- The API is stable and the performance is adequate for this workload.
- The service is compatible with any slog handler (logfmt, JSON, OpenTelemetry bridge) without
  a code change — just swap the handler in `NewLogger`.

zap and zerolog have measurably better performance for extremely high-frequency logging (hundreds
of thousands of log lines per second). At the RPC rates this system handles, the difference is
not observable. The complexity tradeoff (custom field types, `zap.String()` vs `"key", value`) is
not worth it.

logrus is no longer actively maintained and does not support structured fields natively.

---

## 25. TTL values via sync.OnceValue, not init()

**Chosen:** each TTL (sessionTTL, userCacheTTL, presenceTTL) is a package-level `var` holding the
return value of `onceDuration(envKey, defaultVal)`, which calls `sync.Once` internally.

**Alternatives:**
- Read env vars in `main()` and pass TTLs as constructor arguments.
- Read env vars in `init()`.
- `sync.OnceValue` directly for each.

**Reasoning:**

`init()` runs before `main()` and before any test setup. If a test overrides `SESSION_TTL_SECONDS`
via `os.Setenv`, the `init()` value is already cached. `onceDuration` delays the read until first
use — tests that set env vars before calling any redis function get the correct value.

Passing TTLs as constructor arguments would require every call site (`CreateSession`, `SetUserCache`,
`SetPresence`) to accept an extra parameter. This is the right design for dependency-injected
systems but adds noise to a utility library where the TTL is a configuration concern, not a
business logic concern.

`sync.OnceValue` (Go 1.21) would work equivalently but the `onceDuration` helper avoids
repetition across three separate TTL vars.

---

## 26. MaskAmount using HMAC, not redaction or rounding

**Chosen:** `MaskAmount(amount)` returns a 12-character hex HMAC of the amount using a key from
`LOG_AMOUNT_SECRET`.

**Alternatives:**
- Redact entirely: log `"amount": "***"`.
- Round to nearest 1000: log `"amount": 5000` (hides precision).
- Log a hash without a secret key (SHA256 of the amount).

**Reasoning:**

HMAC with a secret key produces a value that:
1. Is consistent: the same amount always produces the same masked value within one deployment.
   This means log correlation works: searching for a specific masked amount across log lines
   identifies all transfers of that amount.
2. Is not reversible without the key: an attacker with access to logs cannot deduce the amounts.
3. Is not a rainbow-table attack surface: amounts are integers with a small domain (e.g. 1–100000).
   A SHA256 without a key could be reversed by brute force across the amount domain.

Redacting entirely (`***`) makes the log useless for anomaly detection (unusual transfer amounts).
Rounding reveals approximate value.

The masking applies only to logs and API responses. The exact amount is always stored correctly
in PostgreSQL (`transfers.amount`).

---

## 27. tracing.Init shutdown — 5-second baked-in timeout

**Chosen:** `tracing.Init` returns a `func(ctx context.Context)` that creates a 5-second
`context.WithTimeout` from the passed ctx before shutting down the OTLP exporter.

**Alternatives:**
- Caller provides a timeout context.
- No timeout — block indefinitely.

**Reasoning:**

On SIGTERM, all services call `defer shutdownTracing(context.Background())`. If the OTLP exporter
is waiting for a response from a collector that is also shutting down (common in `docker-compose
down`), `Shutdown()` would block indefinitely on `context.Background()`. The process would not
exit until the OS sends SIGKILL.

The 5-second timeout baked into the shutdown function means the service always exits within 5
seconds of SIGTERM regardless of the OTLP collector's state. The caller passes
`context.Background()` (or any parent context) and does not need to know the right timeout.

Using `context.WithoutCancel(ctx)` inside the shutdown ensures the parent context's cancellation
(which triggered the shutdown) does not immediately cancel the drain window.

---

## 28. Runner — three-goroutine errgroup lifecycle

**Chosen:** `service.Runner` runs three goroutines in an `errgroup`: NATS consumer, HTTP server,
OS signal handler. The signal handler returns `errShutdown` (not nil) to trigger group
cancellation.

**Alternatives:**
- Two goroutines (consumer + server), with signal handling in main.
- A channel-based shutdown without errgroup.

**Reasoning:**

The errgroup pattern ensures that if any goroutine returns an error (e.g. HTTP `ListenAndServe`
fails on port conflict), the group context is cancelled and all other goroutines are told to stop.
This prevents the zombie scenario where the HTTP server is down but the NATS consumer keeps
processing requests that have nowhere to respond to.

The signal goroutine returns `errShutdown` (a sentinel, not nil) to trigger group cancellation
without propagating as a real error. The final `g.Wait()` call filters out `errShutdown` and only
returns non-nil for genuine failures.

The HTTP `Shutdown()` call uses `context.WithoutCancel(ctx)` + a 10-second drain window. Without
`WithoutCancel`, the ctx passed to `Shutdown` would already be cancelled (because `errShutdown`
triggered cancellation), and `Shutdown` would return immediately without draining in-flight
requests.

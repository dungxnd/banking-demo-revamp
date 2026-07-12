# Go Migration Plan — Full Services Rewrite

Migrate all four Python RPC consumer services and the shared `common/` library to Go,
building on the already-completed `producer/` rewrite.

## Architecture target

```
banking-demo/
├── go.work                        ← Go workspace (links all modules)
├── internal/                      ← shared Go library (replaces common/)
│   ├── go.mod                     (module: banking-demo/internal)
│   ├── amqp/      ← rabbitmq_utils.py  consumer loop + reply_rpc
│   ├── db/        ← db.py + models.py  pgx pool + generated bob models
│   ├── redis/     ← redis_utils.py     session, cache, pub/sub
│   ├── auth/      ← auth.py            bcrypt hash/verify
│   ├── logging/   ← logging_utils.py   slog handler, mask helpers
│   ├── metrics/   ← observability.py   Prometheus base setup
│   └── tracing/   ← observability.py   OTel init (extracted from producer)
│
├── producer/                      ← ✅ done
│   └── go.mod
│
└── services/
    ├── auth-service/
    │   └── go.mod
    ├── account-service/
    │   └── go.mod
    ├── transfer-service/
    │   └── go.mod
    └── notification-service/
        └── go.mod
```

Nothing visible to Kong, the frontend, or RabbitMQ changes —
queue names, Redis key layout, Postgres schema, and the AMQP RPC message format
are all identical. Go services are drop-in replacements behind the same
Docker Compose service names.

---

## Database access: bob

Use **[stephenafamo/bob](https://github.com/stephenafamo/bob)** as the DB layer across all services.

**Why bob fits this project specifically:**

| Requirement | How bob handles it |
|---|---|
| Dynamic `WHERE` (admin search by username / phone / account) | Composable query mods — `sm.Where(...)` built at runtime |
| `SELECT FOR UPDATE` on two rows (transfer atomicity) | `psql.ForUpdate()` mod — first-class, not a raw string |
| Typed models from schema | `bobgen-psql` generates structs from live Postgres |
| Test data / seed | Factory generator replaces `seed.py` |
| Paginated queries with optional filters | Mods composed conditionally, no string building |
| Simple fixed queries | Generated model helpers — `models.Users.Query(...).One(ctx, db)` |

**sqlc** was considered and rejected: it cannot build dynamic `WHERE` clauses
(the admin search endpoint needs optional ILIKE filters across three columns).
`pgx` raw was considered: viable, but requires hand-writing every `rows.Scan()`.

**Schema prerequisite:** bob is database-first. Before `bobgen-psql` can generate
models, SQL migration files must exist. Write them once using
`golang-migrate` — they become the source of truth replacing `Base.metadata.create_all()`.

---

## Phases

### Phase 0 — Workspace + internal scaffold
**Effort: ~0.5 day**

- Create `go.work` at repo root:
  ```
  go 1.26
  use ./internal
  use ./producer
  use ./services/auth-service
  use ./services/account-service
  use ./services/transfer-service
  use ./services/notification-service
  ```
- Create `internal/go.mod` (`module banking-demo/internal`)
- Write SQL migration files for `users`, `transfers`, `notifications` tables
  (schema inferred from SQLAlchemy models — three tables, six indices, two FKs)
- Run `bobgen-psql` → generates `internal/db/models/` (typed structs + CRUD helpers + factories)
- Extract `producer/tracing.go` → `internal/tracing` package; update producer import
- Extract `producer/metrics.go` base setup → `internal/metrics`; update producer import
- Validate: `go build ./...` across the whole workspace

---

### Phase 1 — internal/amqp — RPC consumer framework
**Effort: ~1 day** | Replaces: `common/rabbitmq_utils.py`

This is the most leveraged piece — every service is a thin layer on top of it.
Build it first; the remaining phases become mostly DB query code.

**`Consumer` struct** — mirrors the producer's `rpcClient` reconnect pattern but for the consumer side:
```go
type Handler func(ctx context.Context, action string, payload json.RawMessage, headers map[string]string) (any, error)

type Consumer struct {
    URL       string
    Queue     string
    Logger    *slog.Logger
    Handlers  map[string]Handler  // keyed by action name; "" = default
}

func (c *Consumer) Run(ctx context.Context)  // connect → consume → reconnect loop
```

**Dispatch loop** — for each delivery:
1. Unmarshal `rpcRequest` JSON (same format as producer publishes)
2. Look up handler by `action` field; fall back to `""` default
3. Call handler, collect result or error
4. Call `ReplyRPC` to send response back to `reply_to` queue

**`ReplyRPC`** — publishes `{ "status": N, "body": {...} }` to `delivery.ReplyTo`
with matching `CorrelationId`, `DeliveryMode: Transient`.

**Reconnect** — same backoff pattern as producer: `NotifyClose` → 2 s wait → redial.

**Graceful shutdown** — context cancellation drains the delivery channel before returning.

---

### Phase 2 — internal/db, internal/redis, internal/auth, internal/logging
**Effort: ~1.5 days**

#### internal/db
Replaces `common/db.py` + `common/models.py`.

- pgx v5 connection pool (`pgxpool.New`) configured from `DATABASE_URL` env var
- Pool settings from env: `DB_POOL_SIZE` (default 15), `DB_MAX_OVERFLOW` (default 5)
- `WithTx(ctx, pool, fn)` helper — begins transaction, commits or rolls back
- Generated bob models live in `internal/db/models/` (from Phase 0 bobgen run)
- `LogPoolStatus(logger)` — log pool stats at startup

Key generated types (bob output, not hand-written):
```
models.User, models.Transfer, models.Notification
models.Users  (table helper)
models.Transfers
models.Notifications
```

#### internal/redis
Replaces `common/redis_utils.py`.

- `NewClient(url string) *redis.Client` — go-redis v9 client
- `CreateSession(ctx, client, userID) (string, error)` — UUID → `session:{sid}` with 24 h TTL
- `GetUserIDFromSession(ctx, client, sid) (int, error)` — returns `ErrUnauthorized` if missing
- `SetUserCache(ctx, client, user) error` — `user_cache:phone:{p}` and `user_cache:username:{u}` with 5 min TTL
- `GetUserCache(ctx, client, key) (*CachedUser, error)`
- `SetPresence(ctx, client, userID int, online bool) error` — `presence:{id}` with 60 s TTL
- `PublishNotify(ctx, client, userID int, msg string) error` — publishes to `notify:{id}`
- `Subscribe(ctx, client, channel string) (<-chan string, func())` — returns msg channel + unsubscribe func

#### internal/auth
Replaces `common/auth.py`.

```go
func HashPassword(pw string) (string, error)   // bcrypt, rounds from BCRYPT_ROUNDS env (default 10)
func VerifyPassword(pw, hash string) bool
```
Dependency: `golang.org/x/crypto/bcrypt` (stdlib-adjacent, no new transitive deps).

#### internal/logging
Replaces `common/logging_utils.py`.

- `NewLogger(service string) *slog.Logger` — JSON handler to stdout, service attr pre-set
- `MaskAccount(acct string) string` — `1234****90` format
- `MaskAmount(amount int, secret string) string` — 12-char hex HMAC
- `ShouldLogRequestFlow() bool` — reads `LOG_REQUEST_FLOW` env var

---

### Phase 3 — auth-service
**Effort: ~1 day** | Queue: `auth.requests` | Actions: `register`, `login`

Dependencies: Postgres + Redis.

```
services/auth-service/
├── go.mod
├── main.go      — config, wire Consumer + DB + Redis, run
└── handlers.go  — handleRegister, handleLogin
```

**`handleRegister`:**
1. Validate phone (digits only, non-empty)
2. Check duplicate phone: `models.Users.Query(sm.Where(models.UserColumns.Phone.EQ(...))).Exists(ctx, db)`
3. Generate unique 12-digit account number (retry loop, check uniqueness via bob)
4. Hash password: `internal/auth.HashPassword`
5. Insert: `models.Users.Insert(ctx, db, &models.UserSetter{...})`
6. Return masked phone + account number

**`handleLogin`:**
1. Try Redis cache first: `internal/redis.GetUserCache(ctx, client, key)`
2. On miss: query DB by phone or username, populate cache
3. Verify password: `internal/auth.VerifyPassword`
4. Create session: `internal/redis.CreateSession`
5. Return session token + masked user data

Wire up:
```go
consumer := &amqp.Consumer{
    URL:    cfg.RabbitMQURL,
    Queue:  "auth.requests",
    Logger: logger,
    Handlers: map[string]amqp.Handler{
        "register": handleRegister(db, logger),
        "login":    handleLogin(db, redisClient, logger),
    },
}
go consumer.Run(ctx)
```

---

### Phase 4 — account-service
**Effort: ~1.5 days** | Queue: `account.requests` | Actions: `me`, `balance`, `lookup`, 5× admin

Dependencies: Postgres + Redis.

```
services/account-service/
├── go.mod
├── main.go       — config, wire
├── handlers.go   — user handlers (me, balance, lookup)
└── admin.go      — admin handlers (stats, users, transfers, notifications, user-detail)
```

**Session guard** — all non-health handlers call `internal/redis.GetUserIDFromSession` first;
return `{"status": 401}` on `ErrUnauthorized`.

**Admin guard** — admin handlers check `headers["x-admin-secret"]` against `ADMIN_SECRET` env var.

**Dynamic admin search** (the reason sqlc was ruled out):
```go
mods := []bob.Mod[*dialect.SelectQuery]{
    sm.OrderBy(models.UserColumns.ID.DESC()),
    sm.Limit(psql.Arg(size)),
    sm.Offset(psql.Arg((page - 1) * size)),
}
if search != "" {
    pattern := "%" + search + "%"
    mods = append(mods, sm.Where(
        psql.Or(
            models.UserColumns.Username.ILIKE(psql.Arg(pattern)),
            models.UserColumns.Phone.ILIKE(psql.Arg(pattern)),
            models.UserColumns.AccountNumber.ILIKE(psql.Arg(pattern)),
        ),
    ))
}
users, err := models.Users.Query(mods...).All(ctx, db)
```

**Admin transfers** — fetch page, collect unique user IDs, single `WHERE id = ANY($1)` query,
build `map[int]string{id: username}` for response assembly.

---

### Phase 5 — transfer-service
**Effort: ~1.5 days** | Queue: `transfer.requests` | Default action: transfer

Dependencies: Postgres (row-locking tx) + Redis (session + pub/sub).

> ⚠ **Most correctness-critical service.** The `SELECT FOR UPDATE` on two rows
> must use **deterministic lock ordering** (lower user ID locked first) to
> prevent deadlocks when two users transfer to each other simultaneously.

```
services/transfer-service/
├── go.mod
├── main.go      — config, wire
└── handlers.go  — handleTransfer
```

**`handleTransfer` flow:**
```go
err = internal_db.WithTx(ctx, pool, func(ctx context.Context, tx pgx.Tx) error {
    // 1. Resolve receiver — single query, OR across account_number / phone / username
    // 2. Determine lock order — min(senderID, receiverID) locked first
    // 3. Lock both rows
    firstID, secondID := lockOrder(senderID, receiverID)
    first,  _ = models.Users.Query(sm.Where(...firstID...), psql.ForUpdate()).One(ctx, tx)
    second, _ = models.Users.Query(sm.Where(...secondID...), psql.ForUpdate()).One(ctx, tx)
    sender, receiver = assignRoles(first, second, senderID)

    // 4. Validate balance
    // 5. Update balances via bob setter
    // 6. Insert Transfer record
    // 7. Insert 2 Notification records
    return nil
})
// 8. Post-commit: PublishNotify to receiver (fire-and-forget, Redis)
```

**Log masking:** transfer amounts logged via `internal/logging.MaskAmount`,
account numbers via `internal/logging.MaskAccount`.

---

### Phase 6 — notification-service
**Effort: ~2 days** | Queue: `notification.requests` | Also: WebSocket on `/ws`

Dependencies: Postgres + Redis pub/sub.

> ⚠ **Two transports in one process.** RabbitMQ RPC consumer and HTTP/WebSocket
> server must run concurrently — both managed under the same root context.

```
services/notification-service/
├── go.mod
├── main.go      — config, start Consumer goroutine + HTTP server
├── handlers.go  — handleNotifications (RPC)
└── ws.go        — WebSocket upgrade, Redis subscribe loop, presence heartbeat
```

**RPC handler** — straightforward:
```go
func handleNotifications(db *pgxpool.Pool, redisClient *redis.Client) amqp.Handler {
    return func(ctx context.Context, action string, payload json.RawMessage, headers map[string]string) (any, error) {
        userID, err := internal_redis.GetUserIDFromSession(ctx, redisClient, headers["x-session"])
        // SELECT * FROM notifications WHERE user_id = $1 ORDER BY created_at DESC LIMIT 50
        items, err := models.Notifications.Query(
            sm.Where(models.NotificationColumns.UserID.EQ(psql.Arg(userID))),
            sm.OrderBy(models.NotificationColumns.CreatedAt.DESC()),
            sm.Limit(psql.Arg(50)),
        ).All(ctx, db)
        return items, err
    }
}
```

**WebSocket handler** — uses `coder/websocket` (context-aware, `net/http` compatible):
1. Validate session from query param → get `userID`
2. Subscribe: `msgCh, unsub := internal_redis.Subscribe(ctx, client, fmt.Sprintf("notify:%d", userID))`
3. Goroutine A — presence heartbeat: `SetPresence(online=true)` every 20 s, cancel on WS close
4. Goroutine B — pump Redis messages → `ws.Write(ctx, websocket.MessageText, msg)`
5. On WS close: `unsub()`, `SetPresence(online=false)`

**HTTP server** — minimal chi router (same pattern as producer):
- `GET /ws` → WebSocket handler
- `GET /health` → readiness check
- `GET /metrics` → Prometheus

---

### Phase 7 — producer cleanup
**Effort: ~0.5 day**

- Replace `producer/tracing.go` with `import "banking-demo/internal/tracing"` (done in Phase 0)
- Replace `producer/metrics.go` base setup with `import "banking-demo/internal/metrics"`
- Confirm `go build ./...` passes clean across the whole workspace
- Update `producer/README.md` to note the internal/ dependency

---

## Key library decisions

| Need | Library | Reason |
|---|---|---|
| DB query builder + ORM gen | `stephenafamo/bob` | Dynamic WHERE, SELECT FOR UPDATE, factory gen |
| DB driver | `jackc/pgx/v5` | Native pgx pool; bob's psql driver wraps it |
| Schema migrations | `golang-migrate/migrate` | Replaces `create_all()`; SQL files become source of truth |
| Redis | `redis/go-redis/v9` | Idiomatic, pub/sub straightforward, wide adoption |
| WebSocket | `coder/websocket` | Context-aware, net/http compatible, actively maintained |
| Password hashing | `golang.org/x/crypto/bcrypt` | Stdlib-adjacent, matches Python pwdlib/bcrypt output |
| HTTP routing | `go-chi/chi/v5` | Already used in producer, net/http compatible |
| Env config | `caarlos0/env/v11` | Already used in producer |

## Effort summary

| Phase | Description | Days |
|---|---|---|
| 0 | Workspace + internal scaffold + migration files + bobgen | 0.5 |
| 1 | `internal/amqp` consumer framework | 1.0 |
| 2 | `internal/db`, `redis`, `auth`, `logging` | 1.5 |
| 3 | auth-service | 1.0 |
| 4 | account-service | 1.5 |
| 5 | transfer-service | 1.5 |
| 6 | notification-service | 2.0 |
| 7 | producer cleanup | 0.5 |
| **Total** | | **~9.5 days** |

## What does not change

- Frontend (React 19 + Vite)
- Kong declarative config and route definitions
- PostgreSQL schema (identical tables, same column names)
- RabbitMQ queue names (`auth.requests`, `account.requests`, etc.)
- AMQP RPC message format (`action`, `path`, `method`, `payload`, `headers`, `correlation_id`)
- Redis key layout (`session:*`, `user_cache:*`, `presence:*`, `notify:*`)
- Docker Compose service names and port bindings
- Environment variable names (all services use the same vars)

# Performance Benchmark Suite — Go vs Python

> **Resource caps**: both stacks use `tests/perf/docker-compose.override.yml` — identical CPU/memory limits for a fair comparison.

Compares the **Go stack** (`golang` branch) against the **Python stack** (`origin/final` branch) under realistic production traffic using [k6](https://k6.io/).

```
tests/perf/
├── run-bench.ps1                              ← automated Go-vs-Python benchmark (runs both stacks)
├── generate-report.ps1                        ← parses k6 JSON → unified HTML report (all scenarios)
├── seed-go-stack.ps1                          ← manual helper: migrate + register perf users
├── docker-compose.override.yml               ← resource caps for Go stack stress testing
├── docker-compose.python.override.yml        ← resource caps for Python stack
├── docker-compose.nocap.override.yml         ← removes ALL caps (use with SCENARIO=capacity)
├── docker-compose.python.yml
├── python-kong/kong.yml
├── README.md
└── k6/
    ├── scenario.js
    └── lib/helpers.js
```

---

## Scenarios

| Scenario            | Purpose                        | What it isolates                                     |
|---------------------|--------------------------------|------------------------------------------------------|
| `reg_throughput`    | Registration benchmark         | bcrypt + DB INSERT throughput (open arrival-rate)    |
| `single_pair`       | Contention ceiling             | DB row-lock ceiling under SERIALIZABLE — all VUs on one alice↔bob pair |
| `multi_user`        | True app throughput (**primary signal**) | Framework + message bus + Redis pipeline overhead with near-zero lock contention |
| `fan_out`           | Hot-account stress             | SERIALIZABLE behavior with N senders → 1 hot receiver (merchant pattern) |
| `transfer_journey`  | **Sequential user journey** ★  | Full transfer→confirm cycle latency — each VU does `POST /transfer` → wait → `GET /balance` → think time, strictly sequential |
| `capacity`        | Throughput ceiling (**breakpoint**) | Open arrival-rate ramp; finds max sustainable RPS before errors/latency breach. Requires `docker-compose.nocap.override.yml` |

---

## Traffic Mix

### `multi_user` / `single_pair` / `fan_out` — weighted dice per iteration

| Operation      | Weight  | What it tests                                       |
|----------------|---------|-----------------------------------------------------|
| `auth_check`   | 20%     | `GET /profile` — session lookup + Redis cache       |
| `transfer`     | **60%** | `POST /transfer` — SERIALIZABLE tx + Redis pipeline |
| `balance_read` | 20%     | `GET /balance` — Redis hash read with DB fallback   |

> Transfer is weighted 60% because it's the primary bottleneck in both stacks.
> Each iteration picks **one** action randomly. Use `transfer_journey` if you
> want strict sequential transfer → confirm cycles instead.

### `transfer_journey` — strict sequential steps per iteration

```
iteration N:
  1. POST /transfer  ────► wait for 200 + transfer_id
  2. GET  /balance   ────► wait for 200 + balance value   ← confirms credit landed
  3. sleep(100–300ms)                                      ← think time (not in journey_latency)
  repeat
```

One VU never has two requests in-flight at the same time. This is the **correct model**
for measuring "how long does a complete transfer + confirmation cycle take for a single user?"

---

## Think Time vs Service Throughput Ceiling

| Goal | Think time | Executor | File |
|---|---|---|---|
| Realistic user pacing (comparison) | 100–300ms | `ramping-vus` | `docker-compose.override.yml` |
| **Service throughput ceiling** | **0ms** | **`ramping-arrival-rate`** | **`docker-compose.nocap.override.yml`** |

**For multi_user / fan_out / single_pair**: 100–300ms think time is applied after each iteration. With 20 VUs and 200ms avg think time, the observable RPS ceiling is `20 / 0.21 ≈ 95 req/s` — correct for comparing Go vs Python under realistic load, but **not** the service's actual capacity.

**For `capacity`**: think time is suppressed automatically. The open arrival-rate executor drives exactly the configured RPS regardless of server speed. Caps are removed so the service code — not the container limit — is the bottleneck.

Override think time: `-e THINK_MIN_MS=50 -e THINK_MAX_MS=200`

---

## Architecture Under Test

Both stacks have **identical topology** — Kong → api-producer → queue → consumers:

```
Go stack (port 8000)                Python/final stack (port 9000)
────────────────────────────        ───────────────────────────────────
Kong → api-producer (Go chi)        Kong → api-producer (Python FastAPI)
  → NATS micro RPC                    → RabbitMQ AMQP (aio_pika)
  → Go consumer services               → Python consumer services
  → PostgreSQL (SERIALIZABLE)          → PostgreSQL (READ COMMITTED)
  → Redis HSET balance model           → Redis pub/sub notify only
```

---

## Metrics Collected

### Latency (Trend — measured via `res.timings.duration`)

All per-request latency metrics use k6's built-in `res.timings.duration` — the full HTTP round-trip (DNS + TCP + TLS + server wait + body receive). `journey_latency` uses `Date.now()` wall-time to span both steps of the cycle.

| Metric                   | Description                                          |
|--------------------------|------------------------------------------------------|
| `transfer_latency`       | Full transfer RTT: avg / p50 / p90 / p95 / p99 / max |
| `auth_latency`           | Profile endpoint RTT                                 |
| `balance_latency`        | Balance endpoint RTT                                 |
| `reg_latency`            | Registration endpoint RTT (reg_throughput scenario)  |
| `journey_latency`        | **Full cycle wall-time**: POST /transfer + GET /balance (no think time). Use for end-to-end user experience SLO. |
| `journey_status_latency` | Just the GET /balance step within the journey — measures whether balance read is Redis-cached correctly. |

### HTTP Sub-Timings (transfer only)

| Metric                | Description                                           |
|-----------------------|-------------------------------------------------------|
| `transfer_waiting`    | TTFB — time from request sent to first byte received (queue backlog + DB wait proxy) |
| `transfer_connecting` | TCP connect time — high = connection pool exhaustion  |
| `transfer_receiving`  | Body receive time                                     |

### Error & Retry Rates

| Metric                  | Description                                      |
|-------------------------|--------------------------------------------------|
| `transfer_errors`       | Rate of non-200 transfer responses               |
| `auth_errors`           | Rate of non-200 auth/profile responses           |
| `balance_errors`        | Rate of non-200 balance responses                |
| `serialization_retries` | Rate of 503 (Go: exhausted SERIALIZABLE retries) |
| `reg_errors`            | Rate of non-201 registration responses           |

### Business Counters

| Metric                  | Description                         |
|-------------------------|-------------------------------------|
| `transfers_completed`   | Total successful transfer count     |
| `transfer_amount_total` | Cumulative transfer volume (units)  |
| `regs_completed`        | Total successful registrations      |

---

## SLO Thresholds (defined in `k6/scenario.js`)

k6 exits with code 99 when thresholds are breached. `run-bench.ps1` notes this but does **not** abort — you still get all results and the HTML report.

### `multi_user` / `single_pair` / `fan_out`

```
checks                rate  > 99%     (at least 99% of all inline checks must pass)
transfer_latency      p(95) < 1500ms,  p(99) < 3000ms
transfer_errors       rate  < 2%
serialization_retries rate  < 5%       (>5% = DB contention ceiling)
auth_latency          p(95) < 500ms
auth_errors           rate  < 1%
balance_latency       p(95) < 200ms
balance_errors        rate  < 1%
transfer_waiting      p(95) < 1200ms   (TTFB SLO)
transfer_connecting   p(99) < 50ms     (connection pool health)

# Group-scoped built-in duration thresholds (redundant but visible in terminal output)
http_req_duration{group:::transfer}     p(95) < 2000ms
http_req_duration{group:::balance_read} p(95) < 500ms
http_req_duration{group:::auth_check}   p(95) < 500ms
```

### `transfer_journey`

```
checks                 rate  > 99%
journey_latency        p(95) < 3000ms,  p(99) < 5000ms   ← full cycle (transfer + balance)
journey_status_latency p(95) < 200ms                      ← balance-read step only
journey_errors         rate  < 2%                         ← either step failed
transfer_errors        rate  < 2%
balance_errors         rate  < 1%
serialization_retries  rate  < 5%
transfer_waiting       p(95) < 1200ms
transfer_connecting    p(99) < 50ms
```

### `reg_throughput`

```
reg_latency           p(95) < 2000ms,  p(99) < 4000ms
reg_errors            rate  < 1%
```

---

## Prerequisites

| Tool             | Version    | Install                                      |
|------------------|------------|----------------------------------------------|
| `podman`         | 5.x (WSL2) | Already installed                            |
| `podman compose` | via docker-compose.exe delegate | Already installed |
| Internet         | —          | For pulling `grafana/k6` and base images     |

No local k6 install needed — it runs via `podman run grafana/k6:latest`.

---

## Quick Start

### Automated (recommended)

```powershell
# One-time prerequisite: fetch the Python source
git fetch origin final

# From repo root — runs both stacks sequentially, shows side-by-side summary + HTML report
.\tests\perf\run-bench.ps1

# Fast smoke test (5 VUs, 10s ramp, 30s steady)
.\tests\perf\run-bench.ps1 -MaxVUs 5 -RampDuration 10s -SteadyDuration 30s

# Only benchmark the Go stack (skip Python build)
.\tests\perf\run-bench.ps1 -SkipPython

# Only benchmark the Python stack
.\tests\perf\run-bench.ps1 -SkipGo

# Skip image rebuild (use cached layers)
.\tests\perf\run-bench.ps1 -NoBuild

# Skip HTML report generation
.\tests\perf\run-bench.ps1 -NoReport
```

### Capacity / breakpoint run (find throughput ceiling)

```powershell
# 1. Start Go stack without resource caps
podman compose -f docker-compose.yml `
               -f tests/perf/docker-compose.nocap.override.yml up -d --build

# 2. Run the capacity scenario (open arrival-rate, zero think time)
podman run --rm --network=host `
  -v "$(pwd)/tests/perf/k6:/scripts" `
  -e STACK_TYPE=go -e BASE_URL=http://localhost:8000 `
  -e SCENARIO=capacity `
  -e CAP_START_RATE=10 -e CAP_MAX_RATE=200 -e CAP_RAMP_DURATION=120s `
  grafana/k6:latest run /scripts/scenario.js

# 3. Generate report including capacity data
.\tests\perf\generate-report.ps1 `
  -GoCapFile  tests/perf/k6/results/go-capacity-summary.json `
  -PyCapFile  tests/perf/k6/results/python-capacity-summary.json
```

> The RPS value at which `transfer_errors` first breaches 2% or `transfer_latency p95` exceeds 1500ms is the service throughput ceiling.

---

### Manual (spin up stack yourself, then run k6 directly)

```powershell
# 1. Start the Go stack
podman compose up -d --build

# 2. Migrate schema + register perf_alice / perf_bob via the register endpoint
.\tests\perf\seed-go-stack.ps1

# 3. Run k6 directly (single scenario)
podman run --rm --network=host `
  -v "$(pwd)/tests/perf/k6:/scripts" `
  -e STACK_TYPE=go -e BASE_URL=http://localhost:8000 `
  -e SCENARIO=multi_user `
  grafana/k6:latest run /scripts/scenario.js

# 3b. Run the sequential journey scenario (transfer → balance → repeat per VU)
podman run --rm --network=host `
  -v "$(pwd)/tests/perf/k6:/scripts" `
  -e STACK_TYPE=go -e BASE_URL=http://localhost:8000 `
  -e SCENARIO=transfer_journey `
  grafana/k6:latest run /scripts/scenario.js

# 4. Generate unified HTML report from all result files
.\tests\perf\generate-report.ps1
```

### Full parameter reference

| Parameter          | Default | Description                                  |
|--------------------|---------|----------------------------------------------|
| `-MaxVUs`          | `20`    | Peak concurrent virtual users                |
| `-RampDuration`    | `20s`   | VU ramp-up stage (warms DB pool, NATS)       |
| `-SteadyDuration`  | `60s`   | Measurement window (metrics recorded here)   |
| `-NumUsers`        | `40`    | User pool size for multi_user / fan_out      |
| `-RegRate`         | `10`    | Target registrations/s for reg_throughput    |
| `-RegDuration`     | `30s`   | Measurement window for reg_throughput        |
| `-HealthTimeout`   | `120`   | Seconds to wait for stack healthy            |
| `-SkipGo`          | `false` | Skip Go phase                                |
| `-SkipPython`      | `false` | Skip Python phase                            |
| `-NoBuild`         | `false` | Reuse cached podman images                   |
| `-NoReport`        | `false` | Skip HTML report generation                  |

---

## Output

### Terminal summary

After both phases, `run-bench.ps1` prints a coloured side-by-side table for all four scenarios. Green = winner, Red = loser, White = within 5% margin.

### HTML report

`generate-report.ps1` writes `tests/perf/results/report-<timestamp>.html` — a fully self-contained, tabbed HTML file:

- **Executive summary cards** — SLO pass/fail count per scenario
- **Tabbed scenarios** — `multi_user`, `single_pair`, `fan_out`, `reg_throughput`, Architecture
- Per-tab: 4 **SVG bar charts** (latency percentiles, HTTP sub-timings, error rates, throughput)
- Per-tab: **colour-coded metric table** with all percentiles (avg / p50 / p90 / p95 / p99 / max)
- Per-tab: **SLO badge table** — PASS / FAIL per threshold per stack, including `checks` pass rate
- **Architecture** tab — stack comparison table, SLO definitions, tuning reference
- No external dependencies — open directly in any browser

```powershell
# View report
start tests\perf\results\report-20250115-143022.html

# Generate from any set of existing result files
.\tests\perf\generate-report.ps1 `
  -GoMultiFile   tests/perf/results/go-multi_user-20250115-143022.json `
  -PythonMultiFile tests/perf/results/python-multi_user-20250115-143022.json `
  -GoSingleFile  tests/perf/results/go-single_pair-20250115-143022.json `
  -GoFanOutFile  tests/perf/results/go-fan_out-20250115-143022.json `
  -GoRegFile     tests/perf/results/go-reg_throughput-20250115-143022.json
```

---

## How It Works

### Port layout

| Component              | Go stack (golang)   | Python stack (final)  |
|------------------------|---------------------|-----------------------|
| Kong proxy             | `localhost:8000`    | `localhost:9000`      |
| api-producer           | internal            | `localhost:9080`      |
| PostgreSQL             | `localhost:5432`    | `localhost:5433`      |
| Redis                  | `localhost:6379`    | `localhost:6380`      |
| RabbitMQ               | —                   | `localhost:5673`      |
| RabbitMQ mgmt UI       | —                   | `localhost:15673`     |
| auth-service           | `localhost:8001`    | `localhost:9001`      |
| account-service        | `localhost:8002`    | `localhost:9002`      |
| transfer-service       | `localhost:8003`    | `localhost:9003`      |
| notification-service   | `localhost:8004`    | `localhost:9004`      |

### Route adaption (k6 `lib/helpers.js`)

| Action    | Go                           | Python                          |
|-----------|------------------------------|---------------------------------|
| Login     | `POST /api/sessions`         | `POST /api/auth/login`          |
| Register  | `POST /api/users`            | `POST /api/auth/register`       |
| Balance   | `GET  /api/users/me/balance` | `GET /api/account/balance`      |
| Profile   | `GET  /api/users/me`         | `GET /api/account/me`           |
| Transfer  | `POST /api/transfers`        | `POST /api/transfer/transfer`   |

### Resource caps (docker-compose.override.yml)

**Both** stacks use the same CPU/memory caps — 0.75 CPU / 256 MB for transfer-service, 0.75 CPU / **512 MB** for postgres. Kong / api-producer are capped at 0.3 CPU. Infrastructure (Kong, NATS/RabbitMQ, Redis) is intentionally uncapped — it must never be an artificial bottleneck.

### Test users

| Stack         | Sender       | Password     | How created                        |
|---------------|--------------|--------------|------------------------------------|
| Go            | `perf_alice` | `Perf@1234`  | k6 `setup()` calls POST /api/users |
| Python/final  | `alice`      | `Password1!` | `seed.py` at container start       |

---

## Understanding Results

Results are saved to `tests/perf/results/`:

```
tests/perf/results/
  go-reg_throughput-20250115-143022.json
  go-single_pair-20250115-143022.json
  go-multi_user-20250115-143022.json
  go-fan_out-20250115-143022.json
  python-reg_throughput-20250115-143022.json
  python-single_pair-20250115-143022.json
  python-multi_user-20250115-143022.json
  python-fan_out-20250115-143022.json
  report-20250115-143022.html        # unified tabbed HTML report
```

### Key metrics to compare

| Metric                    | What it tells you                                    |
|---------------------------|------------------------------------------------------|
| `transfer_latency p95`    | 95th percentile of POST /transfer end-to-end         |
| `transfer_latency p50`    | Median — typical transfer experience                 |
| `transfer_waiting p95`    | TTFB — how long DB / queue backlog adds to wait      |
| `transfer_connecting avg` | TCP connect — high = connection pool exhaustion      |
| `http_reqs rate`          | Total throughput (req/s) across all operations       |
| `transfers_completed`     | Successful transfer business volume                  |
| `transfer_errors rate`    | Error rate — should be < 2%                          |
| `serialization_retries`   | Go-only: SERIALIZABLE tx conflict rate               |
| `checks` rate             | Inline assertion pass rate — should be ≥ 99%         |

### Diagnosing anomalies

| Signal                          | Probable cause                  | Action                                                |
|---------------------------------|---------------------------------|-------------------------------------------------------|
| `transfer_waiting p95` spikes   | DB lock queuing (SERIALIZABLE)  | Raise postgres CPU cap, reduce VUs, check index usage |
| `transfer_connecting` rising    | Connection pool exhaustion      | Increase pool size, check for connection leaks        |
| `serialization_retries` > 5%   | SERIALIZABLE conflict ceiling   | Go-specific: reduce concurrency or check missing index|
| auth/balance errors rising      | Redis backpressure / session expiry | Check Redis memory, session TTL                   |
| Python p95 high at > 20 VUs    | asyncio loop + sync SQLAlchemy  | Expected: Python GIL limits concurrency at scale      |

---

## Tuning Tips

- **Increase `MaxVUs`** to find the throughput ceiling. Start at 20, double to 40, 80 until error rate spikes.
- **Transfer-service is the primary bottleneck**: postgres is capped at 0.75 CPU — SERIALIZABLE transactions and lock contention saturate before anything else.
- **Watch `transfer_waiting p95`**: a spike here means DB lock queuing, not application latency.
- **Watch `transfer_connecting avg`**: rising TCP connect times indicate connection pool exhaustion.
- **NATS overhead**: The Go stack adds a NATS round-trip (~0.2ms LAN) that Python skips (direct HTTP). This is visible in p50 but negligible in p95 where DB contention dominates.
- **Python GIL**: Under high VU load (>20), Python's asyncio event loop and the sync SQLAlchemy session pool become the bottleneck. You'll see `transfer_latency` climb steeply past 20 VUs.
- **Go's SERIALIZABLE retry**: PostgreSQL serialisation failures cause Go to return a 503. Under extreme load you may see a spike in `serialization_retries` — this is expected.

---

## Visualising with Grafana (optional)

```powershell
# Start Grafana + InfluxDB locally
podman run -d --name=influxdb -p 8086:8086 influxdb:1.8
podman run -d --name=grafana  -p 3001:3000 grafana/grafana

# Re-run benchmark with InfluxDB output
podman run --rm --network=host `
  -v .\tests\perf\k6:/scripts `
  -e STACK_TYPE=go -e BASE_URL=http://localhost:8000 `
  -e SCENARIO=multi_user `
  grafana/k6:latest run `
  --out influxdb=http://localhost:8086/k6 `
  /scripts/scenario.js
```

Then import dashboard ID **2587** (k6 Load Testing Results) in Grafana.

---

## Python Stack Build Notes

The Python stack is built **without checking out the `final` branch**. The `dockerfile_inline` in `tests/perf/docker-compose.python.yml` runs:

```dockerfile
COPY . /repo
RUN git -C /repo archive origin/final common services/<svc> | tar -x -C /app
```

This extracts the Python source from the `origin/final` git ref, leaving the `golang` working tree untouched. You need `origin/final` to be fetched (one-time):

```powershell
git fetch origin final
```

# PostgreSQL Sensor

> **Source:** https://www.ibm.com/docs/en/instana-observability/current?topic=technologies-monitoring-postgresql
> Condensed for: PostgreSQL 18 StatefulSet in `banking` namespace

---

## How It Works

The Instana PostgreSQL sensor is **automatically deployed** after the host agent runs. It connects to PostgreSQL using the credentials in `configuration.yaml` and queries `pg_stat_*` views.

```
Instana agent (EC2 host)
  └─ JDBC connect → postgres.banking.svc.cluster.local:5432
       └─ SELECT from pg_stat_activity, pg_stat_user_tables,
                      pg_stat_bgwriter, pg_locks, pg_database
```

---

## Supported Versions

| Technology | Support policy | Latest supported |
|------------|---------------|-----------------|
| PostgreSQL | 45 days | 18.4 |

banking-demo uses PostgreSQL 18 (`postgres:18` image in both Docker Compose and Helm chart).

---

## Required: Enable Statistics Collection

The sensor needs PostgreSQL statistics tracking enabled. This is done in banking-demo via the init ConfigMap in [`helm/templates/postgres-init-configmap.yaml`](../../helm/templates/postgres-init-configmap.yaml).

### What's required in `postgresql.conf`

```sql
track_activities = on    -- monitors current command per connection
track_counts = on        -- cumulative stats for table/index access
track_io_timing = on     -- block read/write times
```

### Persistent config (survives restarts)

```sql
ALTER SYSTEM SET track_activities = 'on';
ALTER SYSTEM SET track_counts = 'on';
ALTER SYSTEM SET track_io_timing = 'on';
SELECT pg_reload_conf();

-- Verify
SHOW track_activities;
SHOW track_counts;
SHOW track_io_timing;
```

---

## Agent Configuration

From [`instana/configuration.yaml`](../configuration.yaml):

```yaml
com.instana.plugin.postgresql:
  user: banking
  password: bankingpass
  database: banking
  host: postgres.banking.svc.cluster.local
  port: 5432
```

> **Password must match the cluster Secret** (`helm/values.yaml` `secret.postgresPassword`).
> Using the wrong password produces error code `08004` (SCRAM authentication failure).

> **How auto-discovery works:** The host agent scans running processes on the EC2 node, finds the `postgres` binary via containerd (PID visible at the host level), and connects to the IP/port it reads from the process's listening socket. In the agent log: `Connected to PostgreSQL 'banking'@'10.42.0.12:5432'`.
>
> If auto-discovery doesn't work (e.g., after a pod restart with a new IP), you can explicitly expose PostgreSQL via a NodePort and point the agent there.

---

## Metrics Collected

| Category | Metrics |
|----------|---------|
| Connections | `numbackends`, `max_conn`, active/idle/waiting |
| Transactions | `xact_commit`, `xact_rollback`, TPS |
| I/O | `blks_read`, `blks_hit`, cache hit ratio |
| Locks | Lock types, wait count |
| Tables | Rows inserted/updated/deleted, seq/idx scans |
| Background writer | `buffers_clean`, `checkpoints_timed` |
| Replication | LSN lag (if replicas present) |
| Query performance | Top slow queries (if `pg_stat_statements` enabled) |

---

## How banking-demo Uses PostgreSQL

All banking-demo services connect to PostgreSQL via the `pgxpool` connection pool (Go, via
[`internal/db`](../../internal/db/db.go)). The pool is initialised once at startup with the
`DATABASE_URL` environment variable.

Key tables:

| Table | Owner service | Purpose |
|-------|--------------|---------|
| `users` | auth-service | User accounts and hashed passwords |
| `accounts` | account-service | Account balances (source of truth) |
| `transfers` | transfer-service | Transfer records (uses `SELECT FOR UPDATE`) |
| `notifications` | notification-service | Notification log per user |

---

## Client-Side Tracing

The Go services do not currently use `pgx` OTel hooks. PostgreSQL queries are not represented
as distributed trace spans today — they appear in **Infrastructure → PostgreSQL** via the agent
sensor's `pg_stat_*` polling.

To add per-query PostgreSQL tracing in the future, enable the
[`otelpgx`](https://github.com/exaring/otelpgx) tracer for `pgxpool`:

```go
import "github.com/exaring/otelpgx"

cfg, _ := pgxpool.ParseConfig(databaseURL)
cfg.ConnConfig.Tracer = otelpgx.NewTracer()
pool, _ := pgxpool.NewWithConfig(ctx, cfg)
```

---

## Verifying in Instana UI

1. **Infrastructure → EC2 node → PostgreSQL** — connections, TPS, cache hit ratio
2. **Analytics → Calls** — filter `db.type=postgresql` to see all SQL spans (once OTel tracing is added)
3. End-to-end trace: HTTP request → SQL SELECT visible in one trace (future)

### Troubleshooting

```bash
# Test DB connectivity (from inside the cluster)
kubectl -n banking exec deploy/auth-service -- \
  env | grep DATABASE_URL

# Check agent log
sudo grep -i "postgresql\|postgres" /opt/instana/agent/log/agent.log | tail -20
```

Common issues:
- `postgresql_connection_failed` — check credentials in `configuration.yaml`, verify Service DNS
- Stats views returning 0 — `track_counts`/`track_io_timing` not enabled, run `ALTER SYSTEM SET ...` above

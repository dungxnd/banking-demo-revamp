# Redis Sensor

> **Source:** https://www.ibm.com/docs/en/instana-observability/current?topic=technologies-monitoring-redis
> Condensed for: Redis 8.x StatefulSet in `banking` namespace (no auth, no TLS)

---

## How It Works

The Instana Redis sensor is **automatically installed** after the host agent is running. It connects to Redis using the credentials in `configuration.yaml` and runs `INFO` and `CONFIG GET` commands to collect metrics.

```
Instana agent (EC2 host)
  └─ TCP connect → redis pod IP :6379 (every 10s)
       └─ INFO, CONFIG GET, SLOWLOG GET, LATENCY LATEST
```

---

## Supported Versions

| Technology | Support policy | Latest supported |
|------------|---------------|-----------------|
| Redis | 45 days | 8.8.0 |

banking-demo uses Redis 8.x (from `redis:8-alpine` image in both Docker Compose and Helm chart).

---

## Requirements on Redis Side

- The `CONFIG` command must **not** be disabled or renamed
- The `INFO` command must be accessible
- No password required if Redis runs without auth (banking-demo default)

---

## Agent Configuration

Redis runs as a headless ClusterIP StatefulSet (port 6379, no NodePort) in the current
deployment. The host agent on the EC2 node cannot reach the pod IP directly, so the Redis
sensor block is **commented out** in [`instana/configuration.yaml`](../configuration.yaml).

To enable, first expose Redis via a NodePort (e.g. 32002):

```bash
kubectl -n banking expose statefulset redis --type=NodePort --port=6379 \
  --name=redis-nodeport --overrides='{"spec":{"ports":[{"port":6379,"nodePort":32002}]}}'
```

Then add to `configuration.yaml`:

```yaml
com.instana.plugin.redis:
  username: ''   # Redis 6+ ACL username — leave empty if no ACL
  password: ''   # Leave empty if no requirepass
  poll_rate: 10  # seconds between scrapes (default: 1s)
  hosts:
    - host: 'localhost'
      port: 32002   # NodePort — stable even if pod restarts
  # config-command: 'CONFIG'  # rename if you used rename-command CONFIG in redis.conf
```

> **Why NodePort?** The host agent runs on the EC2 node, not inside the cluster network. It cannot resolve `redis.banking.svc.cluster.local`. A NodePort service exposes Redis on EC2 port 32002, which the agent reaches via `localhost:32002`.

---

## ACL Permissions (Redis 6+ — not needed for banking-demo)

If ACL is enabled, create a monitoring user with minimum permissions:

```redis
# In redis.conf or via redis-cli
ACL SETUSER instana-monitor on >password123 ~* -@all \
  +info +config|get +slowlog|get +pubsub|channels +pubsub|numpat +latency|latest
```

---

## Metrics Collected

| Category | Metrics |
|----------|---------|
| Memory | `used_memory`, `mem_fragmentation_ratio` |
| Clients | `connected_clients`, `blocked_clients` |
| Stats | `total_commands_processed`, `instantaneous_ops_per_sec` |
| Replication | `role`, `connected_slaves`, `repl_backlog_size` |
| Keyspace | Per-db keys, expires, avg_ttl |
| Latency | Command latency histograms |
| Slow log | Commands exceeding `slowlog-log-slower-than` |

---

## How banking-demo Uses Redis

banking-demo services use Redis for:

- **Session storage** (`auth-service`) — `session:{sid}` keys, TTL-based expiry
- **User cache** (`auth-service`) — `user_cache:{username}` for fast login lookup
- **Balance read model** (`account-service`) — `balance:{user_id}` updated on every transfer event
- **Pub/sub notifications** (`notification-service`) — `transfer_notify` channel for real-time WebSocket push

All Redis access is from Go services using the [`go-redis`](https://github.com/redis/go-redis) client
via [`internal/redis`](../../internal/redis/redis.go).

---

## Client-Side Tracing

The Go services do not currently use `go-redis` OTel hooks. Redis calls are not represented as
OTel spans today — they appear in **Infrastructure → Redis** via the agent sensor's `INFO` polling
rather than as distributed trace spans.

To add per-command Redis tracing in the future, enable the
[`go-redis/extra/redisotel`](https://github.com/redis/go-redis/tree/master/extra/redisotel) hook:

```go
import "github.com/redis/go-redis/extra/redisotel/v9"

rdb := redis.NewClient(opts)
if err := redisotel.InstrumentTracing(rdb); err != nil {
    // handle
}
```

---

## Verifying in Instana UI

1. **Infrastructure → EC2 node → Redis** — memory, ops/sec, client count
2. **Analytics → Calls** — filter `db.type=redis` to see all Redis spans (once OTel tracing is added)
3. End-to-end trace: HTTP request → Redis GET/SET visible in one trace (future)

### Troubleshooting

```bash
# Test Redis connectivity from EC2 host (via NodePort)
redis-cli -h 127.0.0.1 -p 32002 info server

# Check agent log
sudo grep -i "redis" /opt/instana/agent/log/agent.log | tail -20
```

Common issues:
- `redis_connection_failed` — wrong IP/host, check NodePort: `kubectl -n banking get svc redis-nodeport`
- `redis_config_command_unavailable` — `CONFIG` was renamed, set `config-command` in the agent config

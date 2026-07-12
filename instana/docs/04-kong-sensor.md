# Kong API Gateway Sensor

> **Source:** https://www.ibm.com/docs/en/instana-observability/current?topic=technologies-monitoring-kong-api-gateway
> Condensed for: Kong 3.9 DB-less, remote monitoring from Instana host agent on EC2

---

## How It Works

The Instana Kong sensor is **automatically installed** after the host agent is running. For remote monitoring (agent on EC2 host, Kong inside k3s cluster), configure the sensor with the Kong Admin API address.

```
Instana agent (EC2 host)
  └─ HTTP poll every 30s → kong.banking.svc.cluster.local:8001 (Admin API)
  └─ Prometheus scrape → kong-proxy :8000/metrics (via Prometheus plugin)
```

---

## Prerequisites

### 1. Kong Admin API accessibility

In banking-demo, Kong's admin API is bound to `127.0.0.1:8001` inside the pod (loopback only).
The admin port is **not** exposed via a NodePort in the current deployment, so the host agent
cannot reach it and the Kong sensor block is **commented out** in
[`instana/configuration.yaml`](../configuration.yaml).

### 2. Prometheus plugin enabled

The sensor depends on the Kong Prometheus plugin for latency, bandwidth, and request metrics. Enabled globally in the Kong declarative config (see [`helm/templates/kong.yaml`](../../helm/templates/kong.yaml)):

```yaml
plugins:
  - name: prometheus
    config:
      status_code_metrics: true
      latency_metrics: true
      bandwidth_metrics: true
      upstream_health_metrics: true
```

---

## Supported Versions

| Technology | Support policy | Latest supported |
|------------|---------------|-----------------|
| Kong Gateway (OSS/Enterprise) | On demand | 3.10.0.0 |

Banking-demo uses Kong 3.9.

---

## Agent Configuration

The Kong admin API is not currently reachable from the host agent — see Prerequisites above.
To enable once a Kong admin NodePort (e.g. 32001) is added, add to `configuration.yaml`:

```yaml
com.instana.plugin.kong:
  enabled: true
  dataset_size: 10                         # max rows for service/route metrics
  status_code_group: '2xx,3xx,4xx,5xx'    # status code buckets to collect
  remote:
    - host: '127.0.0.1'
      port: '32001'                        # NodePort — expose admin on this port first
      availabilityZone: 'banking-dung-ec2'
      poll_rate: 30                        # seconds (minimum: 30 per Instana docs)
      protocol: 'http'
      # username: ''   # only if RBAC basic auth enabled
      # password: ''
      # admin_token: ''  # only if Kong-Admin-Token RBAC enabled
```

### Key Notes

- `poll_rate` minimum is **30 seconds** — do not set lower
- Kong admin API must be reachable from the EC2 host before enabling the sensor
- No auth configured — banking-demo Kong runs DB-less without RBAC
- Multiple `remote` entries can be listed for multiple Kong instances

---

## Metrics Collected

| Metric | Description |
|--------|-------------|
| Total HTTP requests | By service, route, status code |
| Kong latency | Time Kong spends processing requests |
| Upstream latency | Time upstream service takes to respond |
| Bandwidth | Ingress/egress bytes per service |
| Upstream health | Status of upstream targets |

---

## Kong Routes Monitored (banking-demo, Go branch)

Kong proxies all API traffic to `api-producer` (port 8080) and WebSocket traffic to `notification-service` (port 8004).

| Route | HTTP method | Upstream | Notes |
|-------|------------|----------|-------|
| `/api/users` | POST | api-producer:8080 | Register / lookup |
| `/api/sessions` | POST, DELETE | api-producer:8080 | Login / logout |
| `/api/users/me` | GET | api-producer:8080 | Profile |
| `/api/users/me/balance` | GET | api-producer:8080 | Balance |
| `/api/transfers` | POST | api-producer:8080 | Initiate transfer |
| `/api/notifications` | GET | api-producer:8080 | Notifications list |
| `/api/health/*` | GET | api-producer:8080 | Per-service health |
| `/api/admin/*` | GET | api-producer:8080 | Admin endpoints |
| `/ws` | — | notification-service:8004 | WebSocket (bypasses api-producer) |

> **Note (Go branch):** All REST API routes go through `api-producer` (the Go Chi HTTP server),
> which forwards them as NATS RPC calls to the consumer services. Only WebSocket connections
> (`/ws`) bypass `api-producer` and reach `notification-service` directly.

---

## Verifying in Instana UI

1. **Infrastructure → EC2 node → Kong** — Kong dashboard with request rates, latency
2. **Services → kong** — service health and call graph
3. Check agent log:

```bash
sudo grep -i "kong" /opt/instana/agent/log/agent.log | tail -20
```

### Common Issue: `kong_admin_api_not_accessible`

Cause: The agent cannot reach the Admin API.

Fix: Verify the Kubernetes Service is reachable from the EC2 host:

```bash
# From EC2 host — test Kong admin API via cluster DNS
curl http://kong.banking.svc.cluster.local:8001/status

# Or use the ClusterIP directly
kubectl -n banking get svc kong -o jsonpath='{.spec.clusterIP}'
curl http://<CLUSTER_IP>:8001/status
```

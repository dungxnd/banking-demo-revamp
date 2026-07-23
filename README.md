# Banking Demo

A full-stack banking application where users can **create an account, log in, check their balance, send money to other users, and receive real-time notifications** when a transfer arrives.

The app has a web interface you open in a browser. Everything you do — logging in, viewing your balance, sending a transfer — happens instantly, and the recipient sees a live notification without refreshing the page.

> **Forked from** [kevinram164/banking-demo](https://github.com/kevinram164/banking-demo) — extended with Go microservices, OpenTelemetry tracing, Helm/Kubernetes deployment, and Instana observability.

---

## What this project demonstrates

- **API gateway pattern** — Kong routes all browser traffic. The frontend never talks directly to any service.
- **Event-driven microservices** — services communicate via NATS message passing, not direct HTTP calls between services.
- **Real-time notifications** — WebSocket push when a transfer lands, powered by Redis pub/sub.
- **CQRS read model** — account balances are served from a Redis cache, kept in sync by a durable event stream (NATS JetStream), with PostgreSQL as the fallback.
- **Production-ready observability** — structured JSON logs, Prometheus metrics on every service, OpenTelemetry distributed tracing, and Instana integration.

---

## Architecture

```mermaid
flowchart TD
    Browser["🌐 Browser"]

    subgraph Edge["Edge Proxy  (Caddy :80/:443, hostPort)"]
        Caddy["Caddy 2.11\nTLS termination · HTTP→HTTPS redirect\nreverse proxy → Kong"]
    end

    subgraph Frontend["Frontend  (nginx :80)"]
        FE["React 19 + Vite SPA"]
    end

    subgraph Gateway["API Gateway  (Kong 3.9 :8000, ClusterIP)"]
        Kong["Kong\nDB-less declarative config\nCORS plugin on all routes"]
    end

    subgraph RPC["HTTP → NATS Bridge"]
        Producer["api-producer  :8080\nsubjectFromPath() → nc.RequestMsgWithContext()"]
    end

    subgraph Messaging["Message Bus  (NATS 2 + JetStream :4222)"]
        NATS["Core NATS — request/reply\neper-action inbox subjects\nnats/micro service framework"]
        JS["JetStream — BANKING_EVENTS\ndurable event log · 30-day retention"]
    end

    subgraph Consumers["Consumer Services  (Go 1.26)"]
        Auth["auth-service  :8001\nbanking.auth.*"]
        Account["account-service  :8002\nbanking.account.*\n+ balance projection consumer"]
        Transfer["transfer-service  :8003\nbanking.transfer.*\n+ JS publisher"]
        Notify["notification-service  :8004\nbanking.notification.*\n+ HTTP/WebSocket server"]
    end

    subgraph Data["Data Layer"]
        PG[("PostgreSQL 18\nusers · transfers · notifications")]
        Redis[("Redis 8\nsession · user_cache · balance hash\npresence · notify pub/sub")]
    end

    Browser -->|":80 / :443"| Caddy
    Caddy -->|"reverse_proxy → ClusterIP"| Kong
    Caddy -->|"reverse_proxy → ClusterIP"| Frontend
    Browser -->|"POST /api/*"| Caddy
    Browser -->|"GET /ws"| Caddy
    Kong -->|"/api/* → strip_path:false"| Producer
    Kong -->|"/ws direct route"| Notify
    Producer -->|"NATS RPC {payload}"| NATS
    NATS --> Auth & Account & Transfer & Notify
    Transfer -->|"banking.events.transfer.completed\nNats-Msg-Id dedup"| JS
    JS -->|"durable pull consumer\nDeliverAllPolicy"| Account
    Transfer -->|"DEL user_cache\nHSET balance\nPUBLISH notify:{id}"| Redis
    Notify -->|"SUBSCRIBE notify:{uid} → WebSocket"| Redis
    Auth & Account & Transfer & Notify --> PG
    Auth & Account & Transfer & Notify --> Redis
```

**How a request flows:** every request hits Caddy first — the sole entry point on ports 80/443. Caddy proxies to Kong (ClusterIP), which routes `/api/*` to `api-producer`. The services communicate internally via NATS. With TLS enabled, Caddy handles certs via Let's Encrypt HTTP-01 challenge (no API token needed).

---

## Services at a glance

| Service | What it does | Port |
|---|---|---|
| `caddy` | Edge proxy — TLS termination, HTTP→HTTPS redirect | 80, 443 |
| `frontend` | React 19 + Vite SPA, served by nginx | 80 |
| `kong` | API gateway — routes, CORS, rate limiting, tracing | 8000 |
| `api-producer` | Translates HTTP requests into NATS messages | 8080 |
| `auth-service` | Register, login, session management | 8001 |
| `account-service` | Balance, profile, admin queries | 8002 |
| `transfer-service` | Send money between accounts | 8003 |
| `notification-service` | Notification history + live WebSocket push | 8004 |
| `postgres` | Primary database (users, transfers, notifications) | 5432 |
| `redis` | Sessions, balance cache, real-time pub/sub | 6379 |
| `nats` | Message bus (request/reply + durable event stream) | 4222 |

---

## Run locally with Docker Compose

**Requirements:** Docker Desktop (or Docker Engine + Compose plugin)

```bash
git clone https://github.com/dungxnd/banking-demo-revamp
cd banking-demo-revamp
docker compose up --build
```

That's it. All services start together. Demo accounts are seeded automatically on first boot.

| What | URL |
|---|---|
| App | http://localhost:3000 |
| Kong proxy (direct API access) | http://localhost:8000 |
| NATS monitoring dashboard | http://localhost:8222 |
| NATS Prometheus metrics | http://localhost:7777/metrics |

To stop everything: `docker compose down`
To wipe the database and start fresh: `docker compose down -v && docker compose up --build`

### Frontend only (without Docker)

If you want to work on just the UI and already have the backend running elsewhere:

```bash
cd frontend
npm install
npm run dev   # opens at http://localhost:5173
```

Update the proxy target in `vite.config.js` to point at your Kong instance.

---

## Deploy to Kubernetes with Helm

### Two deploy paths

This chart is **self-contained** — deploy it on any K8s cluster using just Helm.

| Path | How | When |
|---|---|---|
| **Standalone** | `helm install` directly | You already have a cluster (EKS, GKE, minikube, k3s, etc.) |
| **Via [k8s-spinup](https://github.com/dungxnd/k8s-buildup-ec2-banking)** | Ansible clones this repo + `helm install` | You need the full AWS infra + cluster + app in one shot |



### Standalone deploy (recommended for testing)

**Requirements:** a running K8s cluster with `kubectl` configured, Helm ≥ 3.12, and a `local-path` StorageClass (included by default in k3s).

```bash
git clone https://github.com/dungxnd/banking-demo-revamp
cd banking-demo-revamp

# Deploy with demo credentials (HTTP-only, access via node IP)
helm upgrade --install banking ./helm \
  --namespace banking --create-namespace \
  --wait --timeout 300s
```

The app is available at `http://<any-node-ip>` on port 80 (Caddy binds the host network).

**To enable HTTPS via Let's Encrypt** (HTTP-01 challenge, no API token needed):

```bash
helm upgrade --install banking ./helm \
  -n banking --create-namespace \
  -f helm/values.yaml \
  --set caddy.tls.enabled=true \
  --set caddy.tls.domain=bank.duckdns.org \
  --wait
```

**To use real secrets** instead of the demo `bankingpass`:

```bash
cp helm/values.local.example.yaml helm/values.local.yaml
# Edit helm/values.local.yaml with your actual passwords
helm upgrade --install banking ./helm \
  -n banking --create-namespace \
  -f helm/values.yaml -f helm/values.local.yaml \
  --wait
```

`helm/values.local.yaml` is gitignored — never committed.  
→ See [Environment & Secrets](#environment--secrets) for the full secrets architecture.



### Deploy via k8s-spinup (AWS from scratch)

The companion repo [`k8s-spinup`](https://github.com/dungxnd/k8s-buildup-ec2-banking) provisions the full stack: EC2 instances, K8s cluster, and deploys this chart.

```
┌─────────────────────────┐    ┌──────────────────────────┐
│  k8s-spinup             │    │  banking-demo (this repo)│
├─────────────────────────┤    ├──────────────────────────┤
│  Terraform → 3 EC2 + SG │    │  Source code + Helm chart│
│  Ansible  → kubeadm+K8s │    │  CI builds & pushes image│
│           → Clone this  │    │  Self-contained chart    │
│           → Helm install│    │  No awareness of infra   │
└─────────────────────────┘    └──────────────────────────┘
```

From `k8s-spinup`:

```bash
make all
#  1. Terraform:   3 EC2 + SG (ports 22, 80, 443 only)
#  2. Ansible:     OS → containerd → kubeadm → Cilium
#  3. Ansible:     Clone banking-demo → helm install
#     Output:      http://<EC2_IP> or https://bank.duckdns.org
```

### Check that everything started

```bash
# All pods should show Running within ~60 seconds
kubectl get pods -n banking

# Send a test request (Caddy serves on :80 via hostNetwork)
curl -s http://<node-ip>/api/health

# Consumers print this when they've connected to NATS and are ready
kubectl logs -n banking -l app=auth-service --tail=5 | grep nats_micro_service_started
```

### Tear down

```bash
# Remove the release (keeps data volumes)
helm uninstall banking -n banking

# Remove everything including data volumes and stuck pods
./helm/nuke.sh

# Remove everything AND reinstall from scratch
./helm/nuke.sh --reinstall
```

> **Warning:** `nuke.sh` deletes all PersistentVolumeClaims — database and Redis data is gone permanently.

### Deploy a new image version

Service names with hyphens must be quoted when passed to `--set`:

```bash
helm upgrade banking ./helm -n banking --reuse-values \
  --set 'auth-service.image.tag=sha-abc1234' \
  --set 'account-service.image.tag=sha-abc1234' \
  --set 'transfer-service.image.tag=sha-abc1234' \
  --set 'notification-service.image.tag=sha-abc1234' \
  --set 'api-producer.image.tag=sha-abc1234' \
  --set frontend.image.tag=sha-abc1234
```

### Domains & TLS

By default the app serves plain HTTP on the node's public IP. To enable HTTPS you need a domain whose A record points to your EC2.

The chart uses **DuckDNS** (free dynamic DNS) — EC2 IPs change on stop/start, DuckDNS keeps your domain pointed at the current IP via a cron job.

**Where things live:**

| What | Where | Why |
|---|---|---|
| **Domain name** | `helm/values.local.yaml` → `caddy.tls.domain` | Tells Caddy which domain to get a cert for |
| **DuckDNS token** | `k8s-spinup` (EC2 user-data or Ansible) | Token keeps DNS in sync — infra concern, not app concern |

**banking-demo chart** (this repo):
```yaml
# helm/values.local.yaml
caddy:
  tls:
    enabled: true
    domain: "bank.duckdns.org"        # domain name only, no token
```

**k8s-spinup** (infra repo) — DuckDNS update cron on the EC2:
```bash
# Runs every 5 minutes, keeps bank.duckdns.org → current EC2 public IP
*/5 * * * * root curl -s "https://www.duckdns.org/update?domains=bank&token=YOUR_TOKEN" > /dev/null
```

Deploy:
```bash
helm upgrade banking ./helm -n banking --reuse-values \
  --set caddy.tls.enabled=true \
  --set caddy.tls.domain=bank.duckdns.org \
  --wait
```

Caddy gets a Let's Encrypt cert via HTTP-01 challenge (port 80). No API token needed in the chart — Caddy doesn't talk to DuckDNS, Let's Encrypt does the validation directly.

### Network policies

When `networkPolicies.enabled: true` (default), the chart applies a **default-deny-ingress** policy across the namespace and whitelists only the necessary paths. Egress is fully allowed. Disable on clusters without a CNI that supports NetworkPolicy:

```bash
helm upgrade banking ./helm -n banking --reuse-values \
  --set networkPolicies.enabled=false
```

### Optional: Disable JetStream

JetStream (NATS durable event stream) is on by default and creates a 1 Gi volume for the event log. All services degrade gracefully without it. To disable:

```bash
helm upgrade banking ./helm -n banking --reuse-values \
  --set nats.jetstream.enabled=false
```

### Optional: Run database migrations via Helm

The chart includes a migration job that runs at upgrade time (disabled by default):

```bash
helm upgrade banking ./helm -n banking --reuse-values \
  --set dbMigration.enabled=true
```

To run migrations manually instead:

```bash
kubectl exec -it -n banking deploy/postgres -- \
  psql -U banking banking -f /migrations/<file>.sql
```

---

## Environment & Secrets

### How secrets are managed

Secrets follow a **two-layer override pattern** — no encryption tools, no vault, just git-ignored files.

| File | In git? | Purpose |
|---|---|---|
| `helm/values.yaml` | ✅ committed | Demo credentials (`bankingpass`). Safe to deploy for testing. |
| `helm/values.local.yaml` | ❌ gitignored | Real secrets (passwords, tokens). Never committed. |
| `helm/values.local.example.yaml` | ✅ committed | Template — copy and fill in your values. |

### How it flows

```
values.yaml         ─┐
values.local.yaml   ─┤  helm install -f values.yaml -f values.local.yaml
                      │
          ┌───────────┘
          ▼
   Helm renders:
     ├── Secret ("banking-db-secret")     ← POSTGRES_USER/PASSWORD, DATABASE_URL, REDIS_URL
     ├── Secret ("nats-connection-secret") ← NATS_URL
     └── ConfigMap ("shared-env")         ← LOG_LEVEL, TZ, POSTGRES_HOST, REDIS_HOST, NATS_URL
          │
          ▼
   Services consume via:
     - envFrom: configMapRef → shared-env
     - envFrom: secretRef    → banking-db-secret
     - envFrom: secretRef    → nats-connection-secret
```

### Kubernetes Secrets created

Two `Opaque` Secrets are rendered from values:

**`banking-db-secret`** — consumed by all backend services and Postgres:
```yaml
POSTGRES_USER: "banking"
POSTGRES_PASSWORD: "bankingpass"       # override via values.local.yaml
POSTGRES_DB: "banking"
DATABASE_URL: "postgres://banking:bankingpass@postgres:5432/banking?sslmode=disable"
REDIS_URL: "redis://redis:6379"
```

**`nats-connection-secret`** — consumed by api-producer and all consumers:
```yaml
NATS_URL: "nats://nats:4222"
```

### shared-env ConfigMap

Centralized non-sensitive env vars applied to all backend services:

```yaml
LOG_LEVEL: "info"
TZ: "Asia/Ho_Chi_Minh"
NATS_URL: "nats://nats:4222"
REDIS_HOST: "redis"
REDIS_PORT: "6379"
POSTGRES_HOST: "postgres"
POSTGRES_PORT: "5432"
POSTGRES_DB: "banking"
```

### Override secrets for production

```bash
cp helm/values.local.example.yaml helm/values.local.yaml

# Edit helm/values.local.yaml:
#   secret:
#     postgresPassword: "your-real-password-here"

helm upgrade --install banking ./helm \
  -n banking --create-namespace \
  -f helm/values.yaml -f helm/values.local.yaml \
  --wait
```

### Why no SOPS / Vault / Sealed Secrets?

| Factor | Reality |
|---|---|
| Blast radius | This is a banking **demo**. `bankingpass` is a known demo credential. |
| Complexity budget | SOPS requires age key management, key distribution to CI, key rotation. For a demo, the local file pattern is sufficient. |
| Custom chart design | The chart intentionally separates `values.yaml` (config) from `values.local.yaml` (secrets). This is the simplest pattern that scales to production. |
| Production path | When going to production, swap `values.local.yaml` for External Secrets Operator (ESO) + AWS Secrets Manager, or Sealed Secrets. The chart's Secret templates don't change — only the values source does. |

The **chart itself is production-ready** — the Secret templates use `stringData` (not base64), support any secret backend via `--set` or `-f`, and the service Deployments consume secrets via `secretKeyRef` with configurable key mappings.

### Logs

All services emit structured JSON logs (one JSON object per line). Useful commands:

```bash
# Watch all ERROR-level events in real time
kubectl logs -n banking --all-containers=true -f | grep '"level":"ERROR"'

# Follow completed transfers
kubectl logs -n banking -l app=transfer-service -f | grep '"msg":"transfer_success"'

# Follow balance cache updates
kubectl logs -n banking -l app=account-service -f | grep '"msg":"balance_projection_updated"'
```

### Prometheus metrics

Every service exposes a `/metrics` endpoint. Scrape them with Prometheus or check manually:

```bash
kubectl port-forward -n banking svc/auth-service 8001:8001
curl http://localhost:8001/metrics
```

Key metrics emitted by all consumer services:

| Metric | What it measures |
|---|---|
| `nats_messages_total` | Requests processed, labeled by action and outcome |
| `nats_handler_duration_seconds` | Time spent handling each message type |
| `nats_reconnects_total` | How often a service had to reconnect to NATS |

### OpenTelemetry tracing

Distributed traces are enabled automatically when an Instana agent (or any OTel-compatible collector) is running on the node. Each service Deployment already contains:

```yaml
- name: NODE_IP
  valueFrom:
    fieldRef:
      fieldPath: status.hostIP
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://$(NODE_IP):4317"
```

Traces start flowing as soon as the agent is present — no extra configuration needed.
To point at a different collector (e.g. a standalone OpenTelemetry Collector):

```bash
helm upgrade banking ./helm -n banking --reuse-values \
  --set 'api-producer.extraEnv.OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability:4317' \
  --set 'auth-service.extraEnv.OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability:4317'
```

### NATS service health

The `nats/micro` framework provides built-in observability for all consumer services:

```bash
# Are all services up?
nats micro ping

# How many requests has each service handled?
nats micro stats auth-service
nats micro stats account-service
nats micro stats transfer-service
nats micro stats notification-service
```

---

## Common operations

```bash
# Restart a service after a config change
kubectl rollout restart deployment/auth-service -n banking

# Scale a service (NATS queue groups handle load balancing automatically)
kubectl scale deployment/transfer-service --replicas=3 -n banking

# Open a database shell
kubectl exec -it -n banking deploy/postgres -- psql -U banking banking

# Inspect NATS internals
kubectl port-forward -n banking svc/nats 8222:8222
curl http://localhost:8222/varz    # server info
curl http://localhost:8222/jsz     # JetStream streams and consumers

# Check the JetStream event stream
nats stream info BANKING_EVENTS
nats consumer info BANKING_EVENTS account-service-balance
```

---

## API endpoints

`api-producer` maps URL paths to NATS subjects. Unknown paths return `404` immediately — no NATS round-trip.

| HTTP method + path | Service | What it does |
|---|---|---|
| `POST /api/auth/register` | auth-service | Create a new account |
| `POST /api/auth/login` | auth-service | Log in, receive a session token |
| `GET /api/account/me` | account-service | Current user's profile |
| `GET /api/account/balance` | account-service | Current balance |
| `GET /api/account/lookup` | account-service | Look up another user |
| `GET /api/account/stats` | account-service | Admin: system stats |
| `GET /api/account/users` | account-service | Admin: all users |
| `GET /api/account/transfers` | account-service | Admin: all transfers |
| `GET /api/account/notifications` | account-service | Admin: all notifications |
| `GET /api/account/user-detail` | account-service | Admin: user detail |
| `POST /api/transfer/transfer` | transfer-service | Send money |
| `GET /api/notifications/notifications` | notification-service | Notification history |
| `GET /ws` | notification-service | WebSocket — live transfer events |

---

## Environment variables

These variables are injected from the Helm-managed secret. Override them in `helm/values.yaml` or via `--set`.

| Variable | Default | Used by |
|---|---|---|
| `DATABASE_URL` | `postgres://banking:bankingpass@postgres:5432/banking` | auth, account, transfer, notification |
| `REDIS_URL` | `redis://redis:6379` | auth, account, transfer, notification |
| `NATS_URL` | `nats://nats:4222` | api-producer + all consumers |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | set from node IP at pod start | all services |
| `DB_POOL_SIZE` | `15` | all consumers |
| `SESSION_TTL_SECONDS` | `86400` (24 h) | auth, account, transfer, notification |
| `USER_CACHE_TTL_SECONDS` | `300` (5 min) | auth |
| `PRESENCE_TTL_SECONDS` | `60` | notification |
| `LOG_AMOUNT_SECRET` | _(built-in default key)_ | transfer, account |
| `NATS_TRACE_SAMPLE_RATE` | `0.01` (1%) | api-producer |

---

## Repository layout

```
.
├── go.work                  # Go workspace — links all service modules
├── internal/                # Shared Go library imported by all services
│   ├── nats/                #   NATS consumer framework, JetStream helpers, middleware
│   ├── auth/                #   bcrypt helpers
│   ├── db/                  #   PostgreSQL pool, query builder, typed row structs
│   ├── health/              #   HTTP + NATS readiness handlers
│   ├── logging/             #   JSON logger, data masking (phone, account, amount)
│   ├── metrics/             #   Prometheus helpers
│   ├── redis/               #   Session, balance cache, presence, pub/sub
│   └── tracing/             #   OpenTelemetry provider initialisation
│
├── producer/                # api-producer — HTTP → NATS bridge              (:8080)
│
├── services/
│   ├── auth-service/        # register, login                                (:8001)
│   ├── account-service/     # balance, profile, admin, balance projection    (:8002)
│   ├── transfer-service/    # send money + JetStream event publish           (:8003)
│   └── notification-service/# notification history + WebSocket               (:8004)
│
├── migrations/              # SQL migration files (golang-migrate)
│
├── frontend/                # React 19 + Vite + Tailwind CSS v4 SPA
│   ├── src/
│   ├── Dockerfile           #   multi-stage build: Node → nginx:alpine
│   └── nginx.conf           #   SPA fallback + /api/* and /ws proxy to Kong
│
├── helm/                    # Helm chart — deploys the complete stack to Kubernetes
│   ├── Chart.yaml
│   ├── values.yaml          #   default config — demo credentials, ready to deploy
│   ├── values.local.example.yaml  #   template for gitignored real secrets
│   └── templates/
│       ├── caddy.yaml              #   edge proxy (hostPort, TLS, reverse proxy)
│       ├── kong.yaml               #   API gateway (ClusterIP, DB-less)
│       ├── shared-env.yaml         #   centralized ConfigMap
│       ├── secret.yaml             #   Kubernetes Opaque Secret
│       ├── network-policy-*.yaml   #   default-deny ingress, allow-all egress
│       └── ...                     #   services, datastores, migration job
│
├── monitoring/              # Kubernetes manifests for Prometheus, Grafana, Jaeger
├── instana/                 # Instana agent config, synthetic tests, runbooks
├── docker-compose.yml       # Local dev stack
└── kong-compose.yml         # Kong declarative config for Compose
```

---

## Building images yourself

The CI pipeline builds and pushes images automatically on every commit. To build manually:

```bash
REGISTRY=ghcr.io/your-org/banking-demo

docker build -f producer/Dockerfile                      -t $REGISTRY/api-producer:latest .
docker build -f services/auth-service/Dockerfile         -t $REGISTRY/auth-service:latest .
docker build -f services/account-service/Dockerfile      -t $REGISTRY/account-service:latest .
docker build -f services/transfer-service/Dockerfile     -t $REGISTRY/transfer-service:latest .
docker build -f services/notification-service/Dockerfile -t $REGISTRY/notification-service:latest .
docker build -f frontend/Dockerfile frontend/            -t $REGISTRY/frontend:latest
```

Then update `image.repository` and `image.tag` in `helm/values.yaml` before deploying.

---

## Tech stack

| Layer | Technology |
|---|---|
| Edge proxy | Caddy 2.11 (hostPort, TLS termination, Let's Encrypt) |
| Frontend | React 19, Vite, Tailwind CSS v4 |
| API gateway | Kong 3.9 (DB-less, ClusterIP) |
| HTTP entry | Go + chi router (`api-producer`) |
| Message bus | NATS 2 with `nats/micro` service framework |
| Durable event bus | NATS JetStream (`BANKING_EVENTS` stream) |
| Session / cache / WS push | Redis 8 |
| Backend services | Go 1.26 |
| Database | PostgreSQL 18 |
| Query builder | `stephenafamo/bob` |
| Schema migrations | `golang-migrate` SQL files |
| Auth | bcrypt (`golang.org/x/crypto`) |
| Observability | OpenTelemetry OTLP/gRPC, Prometheus, Instana |
| Packaging | Helm (Helm 3 / Helm 4 compatible) |
| CI | GitHub Actions — GHCR image build + Kubernetes deploy |

---

## Architecture deep-dive

For a deeper look at how everything fits together, see the supplementary docs:

- [`ARCH-NATS-RPC.md`](ARCH-NATS-RPC.md) — NATS request/reply design, `nats/micro` service framework, per-action subject routing, JetStream event bus
- [`MICROSERVICES.md`](MICROSERVICES.md) — per-service action tables, shared `internal/` library, Kong routing config, database schema, Redis key space
- [`OBSERVABILITY.md`](OBSERVABILITY.md) — Prometheus query reference, `nats/micro` stats, self-hosted monitoring stack setup
- [`fork-docs/cqrs-plan.md`](fork-docs/cqrs-plan.md) — CQRS implementation: Redis balance cache, JetStream event projection, PostgreSQL fallback
- [`fork-docs/amqp-to-nats-migration.md`](fork-docs/amqp-to-nats-migration.md) — how the project migrated from AMQP to NATS, including `nats/micro` and per-action subjects

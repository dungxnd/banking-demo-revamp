# Pod & Service Detection — Why Services Don't Appear (and How to Fix It)

> Condensed from: https://www.ibm.com/docs/en/instana-observability
> Condensed for: k3s host-agent on EC2, banking-demo Go/NATS branch (`banking` namespace)
>
> **If you are seeing this after reviewing the agent log and pods are completely missing from
> Infrastructure → Kubernetes, start with [`10-host-agent-k8s-detection-fix.md`](./10-host-agent-k8s-detection-fix.md)
> which contains the root-cause diagnosis from the actual agent log.**

---

## What "Services" Means in Instana

Instana shows **two different things** that are both called "services":

| Instana View | What populates it | How |
|---|---|---|
| **Infrastructure → Kubernetes → Pods** | Containerd sensor auto-discovery | Immediately on agent start |
| **Applications → Services** | OTLP/trace data from the pods | Only after first trace arrives |

> **The core problem**: Infrastructure (pods, containerd entities) is detected automatically. Services in the Application Perspective appear **only after at least one distributed trace flows through the OTLP pipeline** from a pod to the Instana agent.

---

## Why Pods Are Visible but Services Show 0 Calls

The agent log from the current deployment confirms:

```
Activated Sensor for PID 105171   -> Process sensor (Go — api-producer)
Activated Sensor for PID 78468    -> Process sensor (Go — auth-service)
Activated Sensor for PID 78937    -> Process sensor (Go — account-service)
Activated Sensor for PID 77374    -> Process sensor (Go — transfer-service)
Activated Sensor for PID 82901    -> Process sensor (Go — notification-service)
```

These PIDs are the Go services (api-producer, auth, account, transfer, notification). The **Process sensor** detects them as processes. They will appear in:
- **Infrastructure** → as processes on the EC2 host ✔
- **Kubernetes** → as pods (containerd entities) ✔
- **Applications → Services** → ✗ only if OTLP traces are flowing

If OTLP traces are not arriving at the agent (port 4317), services stay invisible at the application level.

---

## Checklist: Why OTLP Traces May Not Flow

### 1. Traefik tracing not active → no entry-point spans

The agent log shows:
```
Instana tracing is not enabled   -> from Traefik sensor
FrameworkEvent ERROR: Service factory returned null (com.instana.agent.traefik.sensor.Traefik)
```

**Cause**: The `HelmChartConfig` was not applied, or Traefik was not restarted after it was applied.

**Fix**:
```bash
# Apply the HelmChartConfig (idempotent — see 05-traefik-sensor.md for full YAML)
kubectl apply -f <your-traefik-helmchartconfig.yaml>

# Restart Traefik to pick up the new config
kubectl -n kube-system rollout restart deployment/traefik
kubectl -n kube-system rollout status deployment/traefik

# Verify Traefik now has OTEL_EXPORTER_OTLP_ENDPOINT set
kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik \
  -o jsonpath='{.items[0].spec.containers[0].env}' | python3 -m json.tool \
  | grep -A2 OTEL_EXPORTER
```

> The `FrameworkEvent ERROR: Service factory returned null` is **transient** — it resolves automatically once Traefik is restarted with OTLP tracing configured. See [`05-traefik-sensor.md`](./05-traefik-sensor.md) for details.

---

### 2. Go services not sending OTLP spans

Each Go service sets the following env vars (in all Deployment templates in `helm/templates/`):
```yaml
- name: NODE_IP
  valueFrom:
    fieldRef:
      fieldPath: status.hostIP
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://$(NODE_IP):4317"
- name: OTEL_SERVICE_NAME
  value: <service-name>           # unique per template
- name: OTEL_RESOURCE_ATTRIBUTES
  value: "service.namespace=banking-demo"
```

`$(NODE_IP)` must expand to the EC2 node's IP **as seen from the pod**. Without `NODE_IP` defined
via `fieldRef`, the `$(NODE_IP)` substitution produces a literal string and the Go OTLP exporter
fails to connect (it silently skips tracing when the endpoint is empty or invalid).

**Verify the endpoint resolved correctly**:
```bash
# Pick any running pod
kubectl -n banking exec deploy/auth-service -- env | grep -E 'NODE_IP|OTEL'
# Expected:
# NODE_IP=10.0.x.x
# OTEL_EXPORTER_OTLP_ENDPOINT=http://10.0.x.x:4317
# OTEL_SERVICE_NAME=auth-service
# OTEL_RESOURCE_ATTRIBUTES=service.namespace=banking-demo
```

**Verify the agent is listening on 4317**:
```bash
# On the EC2 host
sudo ss -tlnp | grep 4317
# Expected: LISTEN 0.0.0.0:4317
```

**Verify traces are arriving at the agent**:
```bash
sudo grep -i "otlp\|opentelemetry\|span" /opt/instana/agent/log/agent.log | tail -20
```

---

### 3. OTel plugin not explicitly enabled

Ensure the Instana agent has OTLP ingestion enabled in [`instana/configuration.yaml`](../configuration.yaml):

```yaml
com.instana.plugin.opentelemetry:
  enabled: true
```

This is already set. If it was missing, spans would be silently dropped.

---

### 4. No traffic hitting the services

Even if OTLP is wired correctly, services appear in Instana **only after a request creates a trace**. Send a test request:

```bash
# Get the EC2 public IP
curl -s http://<EC2-IP>/api/auth/health
curl -s http://<EC2-IP>/api/account/health
```

Within 30–60 s, the services should appear under **Applications → Services** in the Instana UI.

---

## What Each Service Should Look Like in Instana

After traces flow, the Application Perspective shows:

| Service name | Source | Instana entity type |
|---|---|---|
| `api-producer` | `otelhttp.NewHandler` on Chi router | Application Service |
| `auth-service` | `OTEL_SERVICE_NAME=auth-service` (Go) | Application Service |
| `account-service` | `OTEL_SERVICE_NAME=account-service` (Go) | Application Service |
| `transfer-service` | `OTEL_SERVICE_NAME=transfer-service` (Go) | Application Service |
| `notification-service` | `OTEL_SERVICE_NAME=notification-service` (Go) | Application Service |
| `traefik` | Traefik sensor + OTLP | Infrastructure + Application |
| `kong` | Kong Prometheus sensor | Infrastructure metrics only |
| `postgres` | PostgreSQL JDBC sensor | Infrastructure metrics only |
| `redis` | Redis sensor | Infrastructure metrics only |
| `nats` | NATS HTTP monitoring + nats-exporter | Prometheus metrics only |
| `frontend` (Nginx) | Nginx process sensor | Infrastructure only — no OTLP |

> **Note**: `frontend` (plain Nginx), `kong`, and `nats` will **never** appear as Application Services
> because they don't emit OTLP traces. They appear in **Infrastructure** only.
> Services in "Applications → Services" require trace data.

---

## End-to-End Trace Flow (Banking Demo, Go/NATS branch)

```
Browser request
  └─ Traefik (OTLP span → agent :4317, W3C traceparent propagated)
       ├─ path /   → frontend (Nginx — no tracing, infra only)
       └─ path /api/* → Kong (proxy, no native OTLP)
                          └─ api-producer (Go, otelhttp span → agent :4317)
                               └─ NATS RPC → auth/account/transfer/notification-service
                                              (W3C traceparent injected → consumer continues trace as child span)
```

> **NATS trace continuity:** The `api-producer` injects `traceparent` into NATS message headers
> before publish; each consumer service extracts it in `dispatch` and continues the trace as a
> child span. A full end-to-end waterfall (Traefik → api-producer → consumer service) is visible
> in Instana UI. See [`11-nats-monitoring.md`](./11-nats-monitoring.md) for implementation details.

When fully operational, a single browser request produces a **trace waterfall** in Instana that shows all hops.

---

## Application Perspective Setup

The agent detects services automatically from OTLP `service.name` attributes. To group them into a single Application Perspective in the Instana UI:

1. Go to **Instana UI → Applications → + New Application Perspective**
2. Set **both** of these filters (required for IBM Concert import):
   ```
   kubernetes.cluster.name   =  banking-demo-k3s
   AND
   kubernetes.namespace.name =  banking
   ```
3. Name it `banking-demo`
4. All traces from `banking` namespace pods are grouped under this AP

> **IBM Concert requirement:** Concert retrieves data from Instana only for applications whose
> Instana Application Perspective specifies **both** `kubernetes.cluster.name` and
> `kubernetes.namespace.name`. Using only `service.namespace = banking-demo` (an OTel attribute)
> is not sufficient — Concert ignores OTel-only filters. The two K8s label filters above are
> the only ones Concert accepts.
>
> `banking-demo-k3s` comes from `cluster.name` in [`instana/helm-agent-values.yaml`](../helm-agent-values.yaml).
> `banking` comes from `global.namespace` in [`helm/values.yaml`](../../helm/values.yaml).

---

## Full Verification Sequence

Run these steps in order after initial deployment:

```bash
# Step 1 — verify k8s sensor sees pods
kubectl -n banking get pods
# All Running

# Step 2 — confirm OTLP endpoint resolves in pods
kubectl -n banking exec deploy/auth-service -- env | grep OTEL

# Step 3 — restart Traefik (idempotent — safe to repeat; see 05-traefik-sensor.md for YAML)
kubectl apply -f <your-traefik-helmchartconfig.yaml>
kubectl -n kube-system rollout restart deployment/traefik
kubectl -n kube-system rollout status deployment/traefik

# Step 4 — send traffic to generate traces
for i in $(seq 1 10); do
  curl -s http://<EC2-IP>/api/auth/health > /dev/null
  curl -s http://<EC2-IP>/api/account/health > /dev/null
done

# Step 5 — watch agent log for OTLP activity
sudo grep -i "span\|otlp\|auth-service\|account-service" \
  /opt/instana/agent/log/agent.log | tail -30

# Step 6 — check Instana UI (allow 30-60s for data to propagate)
# Applications → Services → auth-service, account-service, transfer-service, notification-service
```

---

## Troubleshooting Quick Reference

| Symptom | Likely cause | Fix |
|---|---|---|
| **Zero pods in Infrastructure → Kubernetes** | `enabled: false` in k8s plugin config, or kubeconfig not readable | See [`10-host-agent-k8s-detection-fix.md`](./10-host-agent-k8s-detection-fix.md) |
| Services show 0 calls | No OTLP traces received | Send traffic; check OTEL endpoint in pods |
| `Instana tracing is not enabled` in agent log | Traefik HelmChartConfig not applied / pod not restarted | `kubectl rollout restart deployment/traefik -n kube-system` |
| `FrameworkEvent ERROR: Service factory returned null` | Traefik sensor init race with tracing-disabled Traefik | Transient; resolves after Traefik restart |
| `NODE_IP` not resolving in pod env | `fieldRef.fieldPath: status.hostIP` missing from Deployment | All Go service templates include the `NODE_IP` fieldRef env var |
| Go service not in Applications/Services | `OTEL_EXPORTER_OTLP_ENDPOINT` not set → `tracing.Init()` installs no-op silently | Check env var; `NODE_IP` + `OTEL_*` vars must be set in Deployment template |
| Agent not listening on 4317 | OTel plugin disabled | Add `com.instana.plugin.opentelemetry: grpc.enabled: true` |
| Pods visible in Infrastructure but not Applications | OTLP not flowing (no traffic, wrong endpoint) | Follow "Full Verification Sequence" above |
| Frontend not in Applications/Services | Nginx has no OTLP — expected | Normal: Nginx appears in Infrastructure only |
| `nginx_status_not_found` in Instana UI | `stub_status` location missing from `nginx.conf` | Add `/nginx_status` location to `frontend/nginx.conf` |
| `Agent could not connect to PostgreSQL on '<pod-ip>:5432'… password is an empty string` (error 08004, repeats every 10 min) | DaemonSet agent auto-discovers the postgres **process** via containerd and starts a second sensor on the pod IP with no credentials. The explicit `configuration.yaml` block (`host: postgres.banking.svc.cluster.local`, `user: banking`, `password: bankingpass`) is the one that actually works. | **Benign** — the auto-discovered sensor cannot be suppressed. Real metrics flow from the config-file sensor. Ignore the pod-IP error in the log. |
| Kong not in Applications/Services | Kong has no OTLP — expected | Normal: Kong appears via Kong Prometheus sensor |
| NATS not in Applications/Services | NATS server itself has no OTLP — expected | NATS metrics via nats-exporter + Prometheus; consumer services appear once W3C traces flow |
| Redis `SSL is disabled... Read timed out` | Transient SSL check timeout at sensor init | **Benign** — sensor retries; check sensor is connected with `grep -i redis agent.log` |
| Discovery timeout warnings in agent log | Normal on first boot — many sensors load simultaneously | **Benign** — sensors still activate; warnings go away after warm-up |
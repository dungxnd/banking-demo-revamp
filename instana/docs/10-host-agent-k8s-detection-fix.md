# k8s Pod & Service Detection — Host-Agent on EC2 (Root Cause Fix)

> Condensed from:
> - https://www.ibm.com/docs/en/instana-observability/current?topic=kubernetes-checking-agent-prerequisites
> - https://www.ibm.com/docs/en/instana-observability/current?topic=kubernetes-administering-agent
> - https://www.ibm.com/docs/en/instana-observability/current?topic=cha-configuring-host-agents-by-using-agent-configuration-file
>
> Condensed for: k3s single-node on EC2, banking-demo golang branch, host-agent (systemd) mode.

---

## Problem Summary (from agent log 2026-07-01)

The agent log shows **14 containers discovered** by the Containerd sensor but the
Kubernetes sensor does not confirm pod/service/namespace discovery. Four distinct issues
were found:

| # | Log evidence | Root cause |
|---|---|---|
| 1 | `Instana tracing is not enabled` (Traefik, twice) + `FrameworkEvent ERROR: Service factory returned null` | Traefik HelmChartConfig not applied / Traefik not restarted — no OTLP entry spans, so Application Services never populate |
| 2 | `Discovery for com.instana.plugin.ebpf took too long (11854 ms)` `Discovery time (64254 ms)` | Discovery timeouts; k8s sensor races with eBPF/GCP/action plugins at startup |
| 3 | No `"Kubernetes sensor activated"` or `"Connected to Kubernetes API"` log line | The k8s plugin may not be reading the kubeconfig — confirm `enabled: true` and kubeconfig permissions |
| 4 | Services in **Applications → Services** show 0 calls | Follows from issue 1: without Traefik OTLP spans there are no entry traces to build application services |

---

## Fix 1 — Verify `enabled: true` in configuration.yaml (most common cause)

The host-agent on k3s **must** have:

```yaml
com.instana.plugin.kubernetes:
  enabled: true
  kubeconfig: /etc/rancher/k3s/k3s.yaml
```

**Why**: `enabled: true` is what switches on the k8s sensor in host-agent mode.
With `enabled: false` (or the key absent), the sensor is registered but immediately
deactivates. The Containerd sensor still discovers raw container IDs, but they are
never correlated to Kubernetes pods/deployments/services/namespaces.

> **Helm/Operator** installs are the opposite: they use `enabled: false` (the
> k8sensor Deployment handles k8s monitoring). If you copied config from a Helm
> example, you may have `false` when you need `true`.

Verify the live config on the EC2 host:

```bash
sudo grep -A3 "plugin.kubernetes" \
  /opt/instana/agent/etc/instana/configuration.yaml
# Expected:
# com.instana.plugin.kubernetes:
#   enabled: true
#   kubeconfig: /etc/rancher/k3s/k3s.yaml
```

After changing the file, restart the agent (the k8s plugin requires a restart to
reinitialise its connection):

```bash
sudo systemctl restart instana-agent
sudo journalctl -u instana-agent -f --no-pager | grep -i "kubernetes\|k3s\|Activated\|ERROR"
```

Expected log within ~60 s:

```
INFO  | Instana agent Discovery started.
INFO  | ... | Installed instana-kubernetes-...
INFO  | Kubernetes sensor activated. Connected to ...
```

---

## Fix 2 — Kubeconfig permissions

The Instana agent process needs **read access** to the k3s kubeconfig:

```bash
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
# Verify
ls -la /etc/rancher/k3s/k3s.yaml
# Expected: -rw-r--r-- ...

# Verify the agent can read it (agent runs as root, so this is a sanity check)
sudo -u root cat /etc/rancher/k3s/k3s.yaml | grep "server:"
# Expected: server: https://127.0.0.1:6443
```

> **k3s quirk**: k3s recreates `k3s.yaml` on each restart with `600` permissions.
> If the agent starts before the chmod runs, it silently fails to connect.
> Add the chmod to the EC2 User Data or a systemd `ExecStartPre` on the agent unit.

---

## Fix 3 — Restart Traefik to enable OTLP tracing (Traefik v3)

The agent log shows the Traefik sensor with `Instana tracing is not enabled` twice,
plus a `FrameworkEvent ERROR: Service factory returned null`. This means Traefik is
running but the `HelmChartConfig` that enables OTLP tracing has not been applied, or
Traefik has not been restarted since the config was applied.

```bash
# 1 — Apply the HelmChartConfig (safe to re-apply; idempotent)
# See 05-traefik-sensor.md for the full HelmChartConfig YAML (Traefik v3 OTLP — no --tracing.instana flag)
kubectl apply -f <your-traefik-helmchartconfig.yaml>

# 2 — Restart Traefik to pick up the new settings
kubectl -n kube-system rollout restart deployment/traefik
kubectl -n kube-system rollout status deployment/traefik --timeout=120s

# 3 — Confirm Traefik has the OTLP env var
kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik \
  -o jsonpath='{.items[0].spec.containers[0].env}' \
  | jq '.[] | select(.name | test("OTEL"))' 2>/dev/null \
  || kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik \
       -o jsonpath='{.items[0].spec.containers[0].env}' | grep -o '"OTEL[^"]*"'
# Expected: OTEL_EXPORTER_OTLP_ENDPOINT = http://10.x.x.x:4317

# 4 — Watch agent log for Traefik sensor re-activation (60 s window)
sudo grep -i "traefik" /opt/instana/agent/log/agent.log | tail -5
# Look for: "Activated Traefik Sensor" (not "Instana tracing is not enabled")
```

> The `FrameworkEvent ERROR: Service factory returned null` is **transient** — it
> resolves by itself once Traefik is restarted with OTLP configured. It does **not**
> require an agent restart.

---

## Fix 4 — Send traffic to generate traces → populate Application Services

Even with everything wired correctly, **Applications → Services** are empty until at
least one request creates a distributed trace. The Kubernetes infrastructure view
(pods, nodes) is populated from the k8s API — no traffic required. Application
services require trace data.

```bash
EC2_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

# Generate 10 requests across all Go services (golang branch routes)
for i in $(seq 1 10); do
  curl -sf "http://${EC2_IP}/api/health"          > /dev/null  # api-producer
  curl -sf "http://${EC2_IP}/api/accounts/health" > /dev/null  # account-service
  sleep 0.5
done

# Watch agent log for OTLP span ingestion
sudo grep -i "span\|otlp\|api-producer\|auth-service" \
  /opt/instana/agent/log/agent.log | tail -20
```

Allow 30–60 s for Instana to populate **Applications → Services**.

---

## Full Recovery Sequence (run in order)

```bash
# --- Step 0: Verify configuration ------------------------------------------
sudo grep -A3 "plugin.kubernetes" /opt/instana/agent/etc/instana/configuration.yaml
# Must show: enabled: true

# --- Step 1: Fix kubeconfig permissions -------------------------------------
sudo chmod 644 /etc/rancher/k3s/k3s.yaml

# --- Step 2: Restart agent --------------------------------------------------
sudo systemctl restart instana-agent
sleep 30

# --- Step 3: Confirm k8s sensor activates -----------------------------------
sudo grep -i "kubernetes\|k3s\|Activated" /opt/instana/agent/log/agent.log | tail -10

# --- Step 4: Verify pods and namespace visible ------------------------------
kubectl -n banking get pods    # should be: all Running

# --- Step 5: Apply Traefik config + restart (Traefik v3 OTLP) ---------------
# See 05-traefik-sensor.md for the HelmChartConfig YAML
kubectl apply -f <your-traefik-helmchartconfig.yaml>
kubectl -n kube-system rollout restart deployment/traefik
kubectl -n kube-system rollout status deployment/traefik

# --- Step 6: Send traffic (golang branch routes) ----------------------------
EC2_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
for i in $(seq 1 15); do
  curl -sf "http://${EC2_IP}/api/health"          > /dev/null  # api-producer
  curl -sf "http://${EC2_IP}/api/accounts/health" > /dev/null  # account-service via NATS
  sleep 1
done

# --- Step 7: Verify OTLP traces arriving ------------------------------------
sudo grep -i "otlp\|span" /opt/instana/agent/log/agent.log | tail -10

# --- Step 8: Check Instana UI (wait 30-60 s) --------------------------------
# Infrastructure → Kubernetes → banking namespace → pods ✔
# Applications → Services → api-producer, auth-service, account-service, ... ✔
```

---

## Diagnostic Commands Reference

```bash
# Agent process running?
sudo systemctl status instana-agent

# Kubernetes sensor activated?
sudo grep -i "kubernetes" /opt/instana/agent/log/agent.log | tail -20

# k8s API reachable from host?
sudo kubectl get nodes
sudo kubectl get pods -n banking

# Kubeconfig permissions
ls -la /etc/rancher/k3s/k3s.yaml    # must be 644

# OTLP port listening
sudo ss -tlnp | grep 4317           # must show LISTEN 0.0.0.0:4317

# Traefik has OTLP env? (Traefik v3 — OTEL_EXPORTER_OTLP_ENDPOINT, not INSTANA_AGENT_ENDPOINT)
kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik \
  -o jsonpath='{.items[0].spec.containers[0].env}' \
  | grep -o '"name":"OTEL[^"]*"'

# Pod OTEL endpoint resolves? (api-producer is the primary OTLP-instrumented entry point)
kubectl -n banking exec deploy/api-producer -- env | grep -E "NODE_IP|OTEL"
kubectl -n banking exec deploy/auth-service -- env | grep -E "NODE_IP|OTEL"
```

---

## Expected State After All Fixes

| Instana UI view | Expected state |
|---|---|
| Infrastructure → Hosts | EC2 node visible |
| Infrastructure → Kubernetes | `banking` namespace with all pods, deployments, services |
| Infrastructure → Processes | api-producer, auth, account, transfer, notification (Go), kong, postgres, redis, traefik PIDs |
| Applications → Services | `api-producer`, `auth-service`, `account-service`, `transfer-service`, `notification-service` |
| Applications → Traces | Trace waterfall: Traefik → Kong → api-producer (Go Chi) — NATS consumers appear as separate services |
| Technology → Kong | Kong API metrics (throughput, latency, status codes) |
| Technology → Redis | Redis 8 memory, ops/sec, keyspace |
| Technology → PostgreSQL | PG 18 connections, query latency, transaction rate |

> **Note**: `frontend` (Nginx), `kong`, and `nats` (server) do **not** appear in Applications → Services —
> they have no OTLP instrumentation. They appear in Infrastructure only. This is expected.
> NATS consumer services (`auth-service`, `account-service`, etc.) appear as Application Services
> once W3C trace propagation flows (producer injects `traceparent`; consumers extract as child span).
> See [`03-opentelemetry.md`](./03-opentelemetry.md) and [`11-nats-monitoring.md`](./11-nats-monitoring.md).

---

## Why Discovery Timeout Warnings Are Benign

The agent log shows:

```
WARN  | Discovery for com.instana.plugin.ebpf took too long (11854 ms)
WARN  | Discovery for com.instana.plugin.gcp took too long (5899 ms)
WARN  | Discovery for com.instana.plugin.action took too long (5396 ms)
WARN  | Discovery for com.instana.plugin.postgresql took too long (5457 ms)
WARN  | Discovery time (64254 ms)
```

These are **normal on first boot** — the dynamic agent downloads and starts many
sensor plugins simultaneously. The total `64254 ms` discovery time is a one-time
cost. After the agent warms up, discovery cycles are fast. The warnings do **not**
indicate that sensors failed — all sensors (`instana-postgresql-sensor`,
`instana-redis-sensor`, `instana-nginx-sensor`, etc.) show `Installed ...` and
`Activated Sensor` messages confirming successful start.

---

## Related Docs

| File | What it covers |
|---|---|
| [`01-agent-install.md`](./01-agent-install.md) | Agent install on EC2, kubeconfig setup |
| [`02-kubernetes-monitoring.md`](./02-kubernetes-monitoring.md) | k8s sensor overview, OTLP pod-to-agent flow |
| [`09-pod-service-detection.md`](./09-pod-service-detection.md) | Infrastructure vs Application detection, OTLP checklist |
| [`05-traefik-sensor.md`](./05-traefik-sensor.md) | Traefik HelmChartConfig, OTLP tracing setup |
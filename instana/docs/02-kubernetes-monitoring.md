# Kubernetes Monitoring — k3s on EC2

> **Source:** https://www.ibm.com/docs/en/instana-observability/current?topic=kubernetes-installing-agent
> https://www.ibm.com/docs/en/instana-observability/current?topic=kubernetes-checking-agent-prerequisites
> Condensed for: k3s single-node on EC2 (banking-demo golang branch, namespace `banking`)
>
> **Recommended install:** The Kubernetes Helm agent (DaemonSet inside k3s) is the preferred
> approach — see [`13-k8s-agent-install.md`](./13-k8s-agent-install.md). This document covers
> the legacy EC2 host-agent (systemd) mode for reference.

---

## How the Instana Agent Works with k3s

The Instana **host agent** runs directly on the EC2 instance (not inside the cluster) and:

1. Reads the k3s kubeconfig at `/etc/rancher/k3s/k3s.yaml`
2. Discovers all pods, deployments, services, namespaces via the Kubernetes API
3. Automatically deploys technology-specific sensors (Kong, Redis, PostgreSQL, Traefik)
4. Forwards spans/metrics from pods via OTLP to port 4317 on the node IP

> **`enabled: true` is required in host-agent mode** (systemd install on EC2). Without it, the
> k8s sensor deactivates immediately, and zero pods/services/namespaces are reported — even
> though the Containerd sensor still shows raw container IDs.
> The `kubeconfig` path must point to the k3s kubeconfig, and the file must be world-readable
> (`chmod 644 /etc/rancher/k3s/k3s.yaml`).

---

## Prerequisites on k3s (EC2)

```bash
# Make kubeconfig readable by the agent (runs as root but good practice)
sudo chmod 644 /etc/rancher/k3s/k3s.yaml

# Verify the cluster is reachable
sudo kubectl get nodes
# Expected: node in Ready state
```

The Instana agent requires **privileged mode** to auto-instrument workloads. On a bare EC2 host agent this is satisfied automatically (no pod security constraints apply to the host process).

### RBAC (if running agent inside cluster)

If you switch to running the agent as a DaemonSet inside k3s (instead of on the host), deploy with Helm:

```bash
helm repo add instana https://agents.instana.io/helm
helm install instana-agent instana/instana-agent \
  --namespace instana-agent \
  --create-namespace \
  --set agent.key=<AGENT_KEY> \
  --set agent.endpointHost=<INSTANA_BACKEND_HOST> \
  --set cluster.name=banking-ec2-k3s \
  --set k8s_sensor.deployment.enabled=true
```

> `k8s_sensor.deployment.enabled=true` is the default. Setting it explicitly follows IBM docs guidance: *"If you specify the `k8s_sensor.deployment.enabled` value, make sure that it is set to `true`."* Without it, the Next Generation K8sensor (which replaced the EOL legacy sensor) may not deploy if the value is accidentally overridden.

The Helm chart creates all required RBAC (ClusterRole, ClusterRoleBinding, ServiceAccount).

---

## What the Kubernetes Sensor Discovers

| Resource | Auto-discovered |
|----------|----------------|
| Pods (all namespaces) | ✔ |
| Deployments / StatefulSets | ✔ |
| Services | ✔ |
| Namespaces | ✔ |
| k3s Traefik ingress | ✔ (via Traefik sensor) |
| NATS JetStream | ✔ (port 8222 HTTP monitor, if enabled) |

### banking-demo namespace resources discovered

| Component | k8s Kind | Instana service name |
|-----------|----------|---------------------|
| api-producer | Deployment | `api-producer` |
| auth-service | Deployment | `auth-service` |
| account-service | Deployment | `account-service` |
| transfer-service | Deployment | `transfer-service` |
| notification-service | Deployment | `notification-service` |
| frontend | Deployment | `frontend` |
| kong | Deployment | `kong` |
| nats | StatefulSet | `nats` |
| postgres | StatefulSet | `postgresql` (sensor) |
| redis | StatefulSet | `redis` (sensor) |
| traefik | DaemonSet (kube-system) | `traefik` (sensor) |

---

## Agent Configuration for k3s

From [`instana/configuration.yaml`](../configuration.yaml):

```yaml
com.instana.plugin.kubernetes:
  enabled: true               # host-agent mode: must be true to monitor k8s
  kubeconfig: /etc/rancher/k3s/k3s.yaml

com.instana.zone:
  name: banking-dung-ec2

com.instana.tags:
  - environment: production
  - team: banking
  - project: banking-demo
```

> **`enabled: true` is required for host-agent installs.** The agent reads the kubeconfig directly
> and reports pods, services, namespaces, and deployments to Instana. With `enabled: false` the
> agent discovers zero Kubernetes resources.
>
> This is different from a Helm/Operator install, where the k8sensor Deployment handles
> Kubernetes monitoring. Run `kubectl get deployments --all-namespaces -l app=k8sensor` — if no
> results, you are in host-agent mode and **must** have `enabled: true`.
>
> **After changing `enabled`, always restart the agent**:
> ```bash
> sudo systemctl restart instana-agent
> sudo grep -i "kubernetes\|Activated" /opt/instana/agent/log/agent.log | tail -10
> ```

The `zone` groups the host in the Application Perspective drop-downs in the Instana UI.

---

## OTLP Flow: Pods → Instana Agent

Each banking-demo pod sends OTLP traces to the **node IP** (not 127.0.0.1) because the agent runs on the host, not inside the cluster network:

```yaml
# In each Deployment (e.g. auth-service.yaml)
env:
  - name: NODE_IP
    valueFrom:
      fieldRef:
        fieldPath: status.hostIP
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://$(NODE_IP):4317"
```

The agent listens on `0.0.0.0:4317` by default and forwards spans to the Instana backend.

---

## Verifying Kubernetes Monitoring

After the agent starts:

1. **Instana UI → Infrastructure** — the EC2 node appears with all k3s pods shown beneath it
2. **Instana UI → Kubernetes** — shows the `banking` namespace with all workloads
3. **Instana UI → Applications → Services** — `api-producer`, `auth-service`, `account-service`, etc. appear **only after first OTLP traces arrive**

> **Important**: Pods being visible in Infrastructure ≠ services visible in Applications. Services appear only after traces flow. See [`09-pod-service-detection.md`](./09-pod-service-detection.md) for the full explanation and fix.

### Logs to check on the agent

```bash
sudo grep -i "kubernetes\|k3s\|banking" /opt/instana/agent/log/agent.log | tail -30
```

---

## Traefik Integration (k3s — Traefik v3 OTLP)

k3s ships Traefik as its built-in ingress. The [`helm/traefik-instana.yaml`](../../helm/traefik-instana.yaml) `HelmChartConfig` patches it with **OTLP tracing** (not the removed `--tracing.instana` flag):

```yaml
# Traefik v3 — vendor-specific backends removed; tracing is OTLP only
env:
  - name: NODE_IP
    valueFrom:
      fieldRef:
        fieldPath: status.hostIP
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://$(NODE_IP):4317"
tracing:
  otlp:
    grpc:
      endpoint: "localhost:4317"
      insecure: true
```

> **Breaking change from Traefik v2:** `--tracing.instana=true` and `INSTANA_AGENT_ENDPOINT`/`INSTANA_AGENT_ENDPOINT_PORT` were **removed in Traefik v3**. Any config using those flags will cause Traefik to fail to start. Use `OTEL_EXPORTER_OTLP_ENDPOINT` instead.

See [`05-traefik-sensor.md`](./05-traefik-sensor.md) for full Traefik v3 OTLP details.
# Instana Docs — banking-demo (Golang / NATS branch, k3s on EC2)

Reference documentation for running Instana observability on the banking-demo stack deployed with [`helm/`](../../helm/).

All docs are condensed from the official IBM Instana docs at <https://www.ibm.com/docs/en/instana-observability> — shortened to what is relevant for our specific stack.

---

## Stack Overview

| Component | Kind | Monitored by |
|-----------|------|-------------|
| k3s (Kubernetes) | Cluster | Instana agent DaemonSet + k8sensor Deployment (Helm/Operator) |
| EC2 Ubuntu instance | Host | Same agent DaemonSet (host metrics auto-collected) |
| Traefik | Ingress | Traefik sensor (auto) |
| Kong 3.9 | API Gateway | Kong sensor (remote, configured) |
| api-producer | Go / Chi HTTP gateway | OTel OTLP → agent :4317 |
| auth / account / transfer / notification services | Go / nats/micro consumers | OTel OTLP → agent :4317 |
| NATS 2.x + JetStream | Message bus | NATS HTTP monitoring (:8222) + nats-exporter |
| frontend | Nginx | Process sensor (auto) |
| PostgreSQL 18 | StatefulSet | PostgreSQL sensor (configured) |
| Redis 8.x | StatefulSet | Redis sensor (configured) |
| Synthetic tests | PoP (cloud) | Synthetic monitoring |

> **Branch note:** This is the `golang` branch. The Python/RabbitMQ stack is on the `final` branch.
> The transport layer changed from **RabbitMQ AMQP** to **NATS Core request/reply + JetStream**.
> All microservices are now written in **Go** using `nats/micro` and `go.opentelemetry.io/otel`.
>
> **Agent install note:** Two deployment modes — **DaemonSet** (`InstanaAgent`, recommended for
> banking-demo) for in-cluster workloads, or **Remote Agent** (`InstanaAgentRemote`) for systems
> you can't install an agent on (DB2, IBM Concert, etc.). See [`13-k8s-agent-install.md`](./13-k8s-agent-install.md).
> The legacy EC2 host-agent docs ([`01-agent-install.md`](./01-agent-install.md)) are kept for reference.

---

## Docs Index

| File | What it covers |
|------|---------------|
| [`13-k8s-agent-install.md`](./13-k8s-agent-install.md) | **✅ Recommended.** Two K8s deployment modes: **DaemonSet** (Helm/Operator, for banking-demo) and **Remote Agent** (Deployment, for external systems with no agent). Helm values, Operator CRs, OTLP endpoint, upgrade/uninstall |
| [`01-agent-install.md`](./01-agent-install.md) | *(Legacy)* Installing the Instana host agent on Ubuntu EC2 via one-liner. Directory layout, kubeconfig access, verification |
| [`02-kubernetes-monitoring.md`](./02-kubernetes-monitoring.md) | What the k8s sensor discovers, OTLP pod-to-agent flow, Traefik HelmChartConfig |
| [`03-opentelemetry.md`](./03-opentelemetry.md) | OTel OTLP ingestion by the agent. Go service instrumentation, pod env vars, trace propagation, troubleshooting |
| [`04-kong-sensor.md`](./04-kong-sensor.md) | Remote Kong monitoring. Prerequisites (Prometheus plugin), `configuration.yaml` block, metrics, troubleshooting |
| [`05-traefik-sensor.md`](./05-traefik-sensor.md) | Traefik metrics + tracing. k3s HelmChartConfig, agent config, what is collected, troubleshooting |
| [`06-redis-sensor.md`](./06-redis-sensor.md) | Redis sensor. NodePort config, ACL requirements, metrics, client-side OTel tracing, troubleshooting |
| [`07-postgresql-sensor.md`](./07-postgresql-sensor.md) | PostgreSQL sensor. Stats tracking setup, agent config, auto-discovery, metrics, client-side OTel tracing, troubleshooting |
| [`08-synthetic-monitoring.md`](./08-synthetic-monitoring.md) | API Script synthetic tests. Creating tests in UI, variables, Smart Alerts, PoP selection |
| [`09-pod-service-detection.md`](./09-pod-service-detection.md) | **⚠️ Services show 0 calls / pods not detected as Services.** How infrastructure vs application detection works, OTLP flow checklist, Application Perspective setup, full verification sequence |
| [`10-host-agent-k8s-detection-fix.md`](./10-host-agent-k8s-detection-fix.md) | **⚠️ (Host-agent only)** Root cause fix for agent not detecting k8s pods/services. Log-based diagnosis, `enabled: true` fix, kubeconfig permissions, Traefik restart, full recovery sequence |
| [`11-nats-monitoring.md`](./11-nats-monitoring.md) | NATS server metrics via `nats-exporter` + Prometheus, `nats micro stats`, JetStream consumer lag, W3C trace propagation across the NATS boundary |
| [`12-ansible-automation-action.md`](./12-ansible-automation-action.md) | Instana Automation Action Ansible sensor — triggering Ansible job templates from Instana events. Config, Action Catalog setup, banking-demo remediation examples |
| [`14-go-sensor.md`](./14-go-sensor.md) | **Instana Go Collector** — `github.com/instana/go-sensor` integrated alongside OTel. Go process dashboard, health signatures, AutoProfile, env var config |

---

## Quick Start: First-Time Setup (Helm — recommended)

The Instana agent is installed as a **separate, one-time step** after `site.yml` completes.
Use the Ansible playbook (recommended — handles SSH, kubeconfig, idempotent upgrade) or run
the Helm command directly on the EC2 node.

### Option A — Ansible (recommended)

```bash
# From infra/ansible/ on your workstation:
./deploy.sh -p install-instana.yml \
  -e agent_key='<YOUR_AGENT_KEY>' \
  -e agent_download_key='<YOUR_DOWNLOAD_KEY>' \
  -e endpoint_host='host.io'

# Optional overrides (shown with defaults):
#   -e endpoint_port=443
#   -e cluster_name=banking-demo-k3s
#   -e zone_name=banking-dung-ec2
#   -e reinstall=false    # set true to force uninstall + reinstall
```

The playbook: adds the Helm repo, runs `helm upgrade --install` (idempotent), waits for the
DaemonSet and k8sensor Deployment to be Ready, then prints verification commands.

### Option B — Helm directly (on the EC2 node)

```bash
# SSH into the EC2 node, then:
# Recommended: use -f instana/helm-agent-values.yaml for all sensor config
helm upgrade --install instana-agent \
  --repo https://agents.instana.io/helm \
  --namespace instana-agent \
  --create-namespace \
  -f instana/helm-agent-values.yaml \
  --set agent.key='<YOUR_AGENT_KEY>' \
  --set agent.downloadKey='<YOUR_DOWNLOAD_KEY>' \
  --set agent.endpointHost='<YOUR_INSTANA_BACKEND_HOST>' \
  instana-agent

# 3. Verify agent DaemonSet + k8sensor are Running
kubectl -n instana-agent get pods
# Expected: instana-agent-<hash> 1/1 Running   k8sensor-<hash> 1/1 Running

# 4. Verify k8s sensor and OTLP activated in agent logs
kubectl -n instana-agent logs ds/instana-agent --tail=50 \
  | grep -i "kubernetes\|Activated\|otlp\|ERROR"
```

After ~30–60 s the cluster and all k3s pods appear in **Instana UI → Infrastructure → Kubernetes**.
Services populate in **Applications → Services** after the first HTTP requests generate traces.

> **For full Helm values, Operator install, and upgrade instructions** see [`13-k8s-agent-install.md`](./13-k8s-agent-install.md).
>
> **Legacy EC2 host-agent setup** (systemd, no Helm): see [`01-agent-install.md`](./01-agent-install.md).
>
> **If pods are still not detected** after a host-agent install: see [`10-host-agent-k8s-detection-fix.md`](./10-host-agent-k8s-detection-fix.md).

---

## Related Files

| File | Description |
|------|-------------|
| [`instana/helm-agent-values.yaml`](../helm-agent-values.yaml) | **Helm values for k8s agent** — pass with `-f` to embed all sensor config; secrets supplied at runtime via `--set` |
| [`instana/instana-agent-remote.cr.yaml`](../instana-agent-remote.cr.yaml) | **InstanaAgentRemote CR** — template for the remote agent Deployment mode; use when monitoring external systems (DB2, IBM Concert, etc.) that have no K8s presence |
| [`instana/configuration.yaml`](../configuration.yaml) | Full sensor config reference (zone, tags, Kong, Redis, PostgreSQL, OTel, tracing headers, secrets) |
| [`instana/configuration-docker-compose.yaml`](../configuration-docker-compose.yaml) | Agent config for local Docker Compose mode |
| [`instana/synthetic/`](../synthetic/) | API Script synthetic tests (`health-checks.js`, `user-login-flow.js`, `transfer-flow.js`, `auth-edge-cases.js`) |
| [`infra/ansible/install-instana.yml`](../../infra/ansible/install-instana.yml) | Ansible playbook — installs / upgrades the Instana agent via Helm; secrets passed via `-e` at runtime |
| [`infra/ansible/deploy.sh`](../../infra/ansible/deploy.sh) | Wrapper script — `./deploy.sh -p install-instana.yml -e agent_key=... -e ...` |
| [`helm/`](../../helm/) | Helm chart deploying all banking-demo services to k3s |
| [`monitoring/`](../../monitoring/) | Self-hosted Prometheus + Grafana + Jaeger + OTel Collector alternative stack |
| [`OBSERVABILITY.md`](../../OBSERVABILITY.md) | Full observability reference (metrics, logs, traces, Instana, Prometheus/Grafana) |

---

## Official Instana Docs (full)

- **Go Collector installation:** <https://www.ibm.com/docs/en/instana-observability?topic=go-collector-installation>
- **Go Collector configuration:** <https://www.ibm.com/docs/en/instana-observability?topic=go-collector-configuration>
- **Go Collector supported libraries:** <https://www.ibm.com/docs/en/instana-observability?topic=go-collector-supported-libraries>
- **Go Collector common operations FAQ:** <https://www.ibm.com/docs/en/instana-observability?topic=go-collector-common-operations>
- **Go OTel integration:** <https://www.ibm.com/docs/en/instana-observability?topic=go-opentelemetry-integration>
- **Kubernetes agent install (Helm / Operator):** <https://www.ibm.com/docs/en/instana-observability?topic=agents-installing-kubernetes>
- Linux EC2 host-agent install: <https://www.ibm.com/docs/en/instana-observability/current?topic=linux-installing-agent>
- EC2: <https://www.ibm.com/docs/en/instana-observability/current?topic=aws-ec2>
- Kubernetes agent prerequisites: <https://www.ibm.com/docs/en/instana-observability/current?topic=kubernetes-checking-agent-prerequisites>
- Instana Helm chart reference: <https://github.com/instana/helm-charts/tree/main/instana-agent#configuration-reference>
- Instana Agent Operator: <https://github.com/instana/instana-agent-operator>
- Remote agent install: <https://www.ibm.com/docs/en/instana-observability?topic=agents-installing-remote-agent>
- OpenTelemetry: <https://www.ibm.com/docs/en/instana-observability/current?topic=opentelemetry>
- Kong: <https://www.ibm.com/docs/en/instana-observability/current?topic=technologies-monitoring-kong-api-gateway>
- Traefik: <https://www.ibm.com/docs/en/instana-observability/current?topic=technologies-monitoring-traefik>
- Redis: <https://www.ibm.com/docs/en/instana-observability/current?topic=technologies-monitoring-redis>
- PostgreSQL: <https://www.ibm.com/docs/en/instana-observability/current?topic=technologies-monitoring-postgresql>
- Synthetic monitoring: <https://www.ibm.com/docs/en/instana-observability/current?topic=instana-synthetic-monitoring>
- Agent configuration file: <https://www.ibm.com/docs/en/instana-observability/current?topic=cha-configuring-host-agents-by-using-agent-configuration-file>
- Service detection (Application Perspectives): <https://www.ibm.com/docs/en/instana-observability/current?topic=instana-application-perspectives>

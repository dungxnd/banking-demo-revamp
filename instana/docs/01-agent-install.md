# Instana Agent Install — Linux EC2 (k3s host)

> **Source:** https://www.ibm.com/docs/en/instana-observability/current?topic=linux-installing-agent
> **Also:** https://www.ibm.com/docs/en/instana-observability/current?topic=agents-installing-amazon-elastic-compute-cloud-amazon-ec2
> Condensed for: Ubuntu EC2 running k3s (banking-demo golang branch)
>
> **Recommended install:** The Kubernetes Helm agent (DaemonSet inside k3s) is the preferred
> approach — see [`13-k8s-agent-install.md`](./13-k8s-agent-install.md). This document covers
> the legacy EC2 host-agent (systemd) mode for reference.

---

## Prerequisites

- **OS:** Ubuntu 20.04/22.04 (Amazon Linux 2/2023 also supported)
- **Arch:** x64 (amd64)
- **Network:** Port 443 outbound to `<instana-backend-host>` and `setup.instana.io`
- **Root / sudo** required for install

---

## One-liner Install (Ubuntu/Debian)

From the Instana UI: **Agents & Collectors → Install agents → Linux — Automatic Installation (One-liner)**

```bash
curl -o setup_agent.sh https://setup.instana.io/agent \
  && chmod 700 ./setup_agent.sh \
  && sudo -E ./setup_agent.sh \
      -a <AGENT_KEY> \
      -d <DOWNLOAD_KEY> \
      -t dynamic \
      -e <INSTANA_BACKEND_HOST> \
      -s   # install + start as systemd service
```

Key parameters:

| Flag | Required | Description |
|------|----------|-------------|
| `-a` | yes | Agent key (from Instana UI → Settings → Agents) |
| `-d` | no  | Download key (same as agent key for SaaS) |
| `-e` | yes | Backend host, e.g. `ingress-red-saas.instana.io` |
| `-t` | no  | `dynamic` (default) or `static` |
| `-s` | no  | Install and start as systemd service |

### EC2-specific: install on every boot via User Data

Paste the script into **EC2 → Instance → User data** to auto-install on each launch.

---

## Post-Install Verification

```bash
# Service status
sudo systemctl status instana-agent

# Tail logs
sudo tail -f /opt/instana/agent/log/agent.log

# One-line health check
sudo instana-agent status
```

After ~30 s the host appears in **Instana UI → Infrastructure**.

---

## Agent Directory Layout

| Path | Purpose |
|------|---------|
| `/opt/instana/agent/` | Agent home |
| `/opt/instana/agent/etc/instana/configuration.yaml` | Main config (hot-reloaded) |
| `/opt/instana/agent/etc/instana/configuration-*.yaml` | Additional configs merged alphabetically |
| `/opt/instana/agent/log/agent.log` | Main log |

---

## banking-demo EC2 Config Location

Mount our config at install time or copy after install:

```bash
sudo cp instana/configuration.yaml \
     /opt/instana/agent/etc/instana/configuration.yaml
```

The agent hot-reloads most settings; a restart is only needed for zone/backend changes.

---

## Kubeconfig Access (k3s)

The Instana Kubernetes sensor needs to read the k3s kubeconfig:

```bash
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
```

This is referenced in [`instana/configuration.yaml`](../configuration.yaml):

```yaml
com.instana.plugin.kubernetes:
  enabled: true           # REQUIRED for host-agent mode on k3s
  kubeconfig: /etc/rancher/k3s/k3s.yaml
```

> **`enabled: true` is mandatory** for the host-agent (systemd) install on k3s. Without it, the Kubernetes sensor never activates and zero pods/services/namespaces are reported.
> The next-gen k8sensor (agent ≥ 1.2.x) still requires `enabled: true` when the agent runs on the host (not inside the cluster). Only an in-cluster Helm/Operator install can use `enabled: false`.

---

## Uninstall

```bash
sudo apt-get remove instana-agent   # Debian/Ubuntu
sudo yum remove instana-agent       # RHEL/Amazon Linux
```

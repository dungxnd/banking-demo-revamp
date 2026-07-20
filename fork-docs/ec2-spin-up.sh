#!/bin/bash
# EC2 User Data — banking-demo on k3s (Amazon Linux 2023 / Ubuntu 26.04)
#
# What this does:
#   1. Install k3s (Kubernetes + containerd, runs as a systemd service on the host)
#   2. Install helm
#   3. Clone the repo (instana branch) into ~/banking-demo (owned by the login user)
#   4. Pull pre-built images from ghcr.io/dungxnd/banking-demo-revamp (CI-built)
#   5. Deploy via Helm
#   6. Install Instana host agent
#   7. Print access URLs
#
# k3s vs k3d: k3s runs directly on the host — the Instana host agent can read
# /etc/rancher/k3s/k3s.yaml, walk /proc for pod PIDs, and reach the k8s API at
# 127.0.0.1:6443 without any extra tunneling. k3d wraps k3s inside Docker
# containers which breaks all three of those requirements.
#
# After first boot, SSH in as the login user — no sudo needed for kubectl/helm/git.
set -euo pipefail

REPO_URL="https://github.com/dungxnd/banking-demo-revamp.git"

# Resolve latest Helm version at runtime — no hardcoded version to go stale.
# k3s ships its own kubectl so we don't need to resolve that separately.
HELM_VERSION=$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest \
  | grep -o '"tag_name": *"[^"]*"' | head -1 \
  | sed 's/.*"tag_name": *"\([^"]*\)"/\1/')

# ── Detect distro + login user ───────────────────────────────────────────────
if [ -f /etc/os-release ]; then
  . /etc/os-release
  DISTRO=$ID
else
  DISTRO=unknown
fi

case "$DISTRO" in
  amzn)   LOGIN_USER="ec2-user" ;;
  ubuntu) LOGIN_USER="ubuntu"   ;;
  *)      LOGIN_USER="ec2-user" ;;
esac

LOGIN_HOME=$(getent passwd "$LOGIN_USER" | cut -d: -f6)
REPO_DIR="$LOGIN_HOME/banking-demo"

# ── 1. Install base packages ──────────────────────────────────────────────────
if [ "$DISTRO" = "amzn" ]; then
  dnf update -y
  dnf install -y git curl tar
elif [ "$DISTRO" = "ubuntu" ]; then
  apt-get update -y
  apt-get install -y ca-certificates curl git tar
fi

# ── 2. Install k3s ────────────────────────────────────────────────────────────
# --disable traefik: Kong is the gateway; it is exposed directly as NodePort on
#   :80 (proxy) so no IngressController is needed — an Ingress resource pointing
#   at a disabled Traefik would simply never be processed.
# --write-kubeconfig-mode 644: Instana host agent must read this file; k3s
#   recreates it as 600 on each restart — setting mode here makes it persistent
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644" \
  sh -

# k3s installs kubectl at /usr/local/bin/kubectl automatically
# Symlink kubeconfig for normal user use (kubectl reads KUBECONFIG or ~/.kube/config)
mkdir -p "$LOGIN_HOME/.kube"
ln -sf /etc/rancher/k3s/k3s.yaml "$LOGIN_HOME/.kube/config"
chown -h "$LOGIN_USER:$LOGIN_USER" "$LOGIN_HOME/.kube" "$LOGIN_HOME/.kube/config"

# ── 3. Install Helm ───────────────────────────────────────────────────────────
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
  | tar -xz -C /usr/local/bin --strip-components=1 linux-amd64/helm

# ── 4. Clone repo ─────────────────────────────────────────────────────────────
sudo -u "$LOGIN_USER" git clone --branch golang "$REPO_URL" "$REPO_DIR"

# ── 5. Pull pre-built images from GHCR into k3s containerd ───────────────────
# Images are built by CI and published to ghcr.io/dungxnd/banking-demo-revamp/<name>.
# k3s containerd pulls them directly — no Docker needed.
GHCR="ghcr.io/dungxnd/banking-demo-revamp"
for svc in api-producer auth-service account-service transfer-service notification-service frontend; do
  k3s ctr images pull "${GHCR}/${svc}:latest"
done

# ── 6. Deploy with Helm ───────────────────────────────────────────────────────
cd "$REPO_DIR/final/helm"

# Images are already in k3s containerd; use IfNotPresent so k3s won't re-pull
# on pod restarts (images are local, no registry auth needed at runtime).
SETS=""
for svc in api-producer auth-service account-service transfer-service notification-service frontend; do
  SETS="$SETS --set ${svc}.image.repository=${GHCR}/${svc}"
  SETS="$SETS --set ${svc}.image.tag=latest"
  SETS="$SETS --set ${svc}.image.pullPolicy=IfNotPresent"
done

# Traefik is disabled — bind Kong proxy to host port 80 via hostPort so the EC2
# security group port 80 reaches Kong directly without any IngressController.
# hostPort bypasses kube-proxy entirely: the node kernel forwards :80 → Kong pod.
SETS="$SETS --set kong.service.hostPort=80"

# Use KUBECONFIG explicitly since this runs as root but the file is at the k3s path
KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
helm upgrade --install banking-demo . \
  --namespace banking --create-namespace \
  -f charts/common/values.yaml \
  -f charts/postgres/values.yaml \
  -f charts/redis/values.yaml \
  -f charts/rabbitmq/values.yaml \
  -f charts/kong/values.yaml \
  -f charts/auth-service/values.yaml \
  -f charts/account-service/values.yaml \
  -f charts/transfer-service/values.yaml \
  -f charts/notification-service/values.yaml \
  -f charts/api-producer/values.yaml \
  -f charts/frontend/values.yaml \
  $SETS

KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
kubectl wait --for=condition=ready pod --all -n banking --timeout=300s

# ── 7. Instana host agent ─────────────────────────────────────────────────────
# Replace <AGENT_KEY> and <BACKEND_HOST> before using, or pass as instance tags.
# The one-liner is generated from: Instana UI → Agents → Install → Linux.
#
# INSTANA_AGENT_KEY="<your-agent-key>"
# INSTANA_BACKEND="ingress-<region>-saas.instana.io"
# curl -o setup_agent.sh https://setup.instana.io/agent \
#   && chmod 700 ./setup_agent.sh \
#   && sudo -E ./setup_agent.sh -a "$INSTANA_AGENT_KEY" -e "$INSTANA_BACKEND" -t dynamic -s
#
# After installing the agent, copy the pre-configured configuration.yaml:
#   sudo cp "$REPO_DIR/instana/configuration.yaml" \
#        /opt/instana/agent/etc/instana/configuration.yaml
#   sudo systemctl restart instana-agent
#
# The config already sets:
#   com.instana.plugin.kubernetes.enabled: true
#   com.instana.plugin.kubernetes.kubeconfig: /etc/rancher/k3s/k3s.yaml
#   com.instana.plugin.opentelemetry.grpc.listenAddress: 0.0.0.0:4317

# ── Done ──────────────────────────────────────────────────────────────────────
# IMDSv2-aware public IP lookup.
# --connect-timeout 3: don't hang if IMDS is slow on first boot.
# Modern EC2 instances enforce IMDSv2 (token required); the IMDSv1 fallback is
# kept only for older launch configs that still have it enabled.
IMDS="http://169.254.169.254"
TOKEN=$(curl -sf --connect-timeout 3 --max-time 5 \
  -X PUT "${IMDS}/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)

if [ -n "$TOKEN" ]; then
  PUBLIC_IP=$(curl -sf --connect-timeout 3 --max-time 5 \
    -H "X-aws-ec2-metadata-token: $TOKEN" \
    "${IMDS}/latest/meta-data/public-ipv4" 2>/dev/null || true)
else
  # IMDSv1 fallback (only works when hop-limit allows it)
  PUBLIC_IP=$(curl -sf --connect-timeout 3 --max-time 5 \
    "${IMDS}/latest/meta-data/public-ipv4" 2>/dev/null || true)
fi

# If the instance has no public IP (private-only VPC), use the private IP instead
if [ -z "$PUBLIC_IP" ]; then
  if [ -n "$TOKEN" ]; then
    PUBLIC_IP=$(curl -sf --connect-timeout 3 --max-time 5 \
      -H "X-aws-ec2-metadata-token: $TOKEN" \
      "${IMDS}/latest/meta-data/local-ipv4" 2>/dev/null || echo "<instance-ip>")
  else
    PUBLIC_IP=$(curl -sf --connect-timeout 3 --max-time 5 \
      "${IMDS}/latest/meta-data/local-ipv4" 2>/dev/null || echo "<instance-ip>")
  fi
fi

echo ""
echo "=== Banking Demo deployed on k3s ==="
echo "  Frontend  : http://${PUBLIC_IP}/          (Kong NodePort :80)"
echo "  Kong API  : http://${PUBLIC_IP}/api/       (Kong NodePort :80)"
echo "  WebSocket : ws://${PUBLIC_IP}/ws           (Kong NodePort :80)"
echo ""
echo "SSH in then:"
echo "  kubectl get pods -n banking"
echo "  kubectl logs -n banking -l app=api-producer -f"
echo ""
echo "Update a single service to a new image:"
echo "  sudo k3s ctr images pull ghcr.io/dungxnd/banking-demo-revamp/api-producer:latest"
echo "  kubectl rollout restart deployment/api-producer -n banking"
echo ""
echo "Instana agent (install manually with your key):"
echo "  See: ~/banking-demo/instana/docs/01-agent-install.md"
echo "  Config: sudo cp ~/banking-demo/instana/configuration.yaml \\"
echo "               /opt/instana/agent/etc/instana/configuration.yaml"
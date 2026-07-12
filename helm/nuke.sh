#!/usr/bin/env bash
# nuke.sh — Completely tear down and reinstall banking-demo on k3s.
#
# Usage:
#   ./helm/nuke.sh                          # tear down only
#   ./helm/nuke.sh --reinstall              # tear down + reinstall
#   KUBECONFIG=/home/ubuntu/.kube/config ./helm/nuke.sh --reinstall
#
# WARNING: This script deletes ALL PersistentVolumeClaims in the banking
# namespace, including postgres-data and redis-data. All database contents
# and Redis state will be permanently lost.
#
# The Instana agent (instana-agent namespace) is NOT touched by this script.

set -euo pipefail

NS="banking"
RELEASE="banking"
CHART="./helm"
VALUES="helm/values.yaml"

# Honour KUBECONFIG env var; default to the user kubeconfig.
export KUBECONFIG="${KUBECONFIG:-/home/ubuntu/.kube/config}"

REINSTALL=false
for arg in "$@"; do
  case "$arg" in
    --reinstall) REINSTALL=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

echo "=== banking-demo nuke ==="
echo "Namespace : $NS"
echo "Release   : $RELEASE"
echo "Reinstall : $REINSTALL"
echo ""

# ── 1. Uninstall Helm release ───────────────────────────────────────────────
echo "--- Uninstalling Helm release '$RELEASE' (namespace $NS)..."
if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
  helm uninstall "$RELEASE" -n "$NS" --wait --timeout 120s || true
  echo "    Helm release removed."
else
  echo "    No Helm release found — skipping."
fi

# ── 2. Delete orphaned StatefulSet PVCs ────────────────────────────────────
# StatefulSet volumeClaimTemplates are NOT managed by Helm — they survive
# helm uninstall regardless. We must delete them manually.
echo "--- Deleting PVCs in namespace $NS..."
PVCS=$(kubectl get pvc -n "$NS" --no-headers -o custom-columns=':metadata.name' 2>/dev/null || true)
if [[ -n "$PVCS" ]]; then
  echo "$PVCS" | xargs -r kubectl delete pvc -n "$NS" --timeout=60s
  echo "    PVCs deleted."
else
  echo "    No PVCs found — skipping."
fi

# ── 3. Delete any remaining pods stuck in Terminating ──────────────────────
echo "--- Force-deleting any stuck pods in namespace $NS..."
STUCK=$(kubectl get pods -n "$NS" --field-selector=status.phase=Failed \
        --no-headers -o custom-columns=':metadata.name' 2>/dev/null || true)
if [[ -n "$STUCK" ]]; then
  echo "$STUCK" | xargs -r kubectl delete pod -n "$NS" --force --grace-period=0
fi

# ── 4. Wait for namespace to clear ─────────────────────────────────────────
echo "--- Waiting for namespace $NS to clear..."
TIMEOUT=60
ELAPSED=0
while [[ $(kubectl get pods -n "$NS" --no-headers 2>/dev/null | wc -l) -gt 0 ]]; do
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "WARNING: Pods still running after ${TIMEOUT}s — proceeding anyway."
    kubectl get pods -n "$NS"
    break
  fi
  sleep 3
  ELAPSED=$((ELAPSED + 3))
done
echo "    Namespace is clear."

# ── 5. Reinstall if requested ───────────────────────────────────────────────
if [[ "$REINSTALL" == "true" ]]; then
  echo ""
  echo "=== Reinstalling banking-demo ==="
  helm upgrade --install "$RELEASE" "$CHART" \
    -n "$NS" \
    --create-namespace \
    -f "$VALUES" \
    --wait \
    --timeout 300s

  echo ""
  echo "=== Deploy complete ==="
  kubectl -n "$NS" get pods
fi

echo ""
echo "Done."

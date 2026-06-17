#!/usr/bin/env bash
# Recreate the open5gs kind cluster and redeploy the full stack.
# Run this after every reboot or Docker restart (Option A: always recreate).
#
# Usage: ./cluster-start.sh [--skip-deploy]
#   --skip-deploy   Recreate the cluster only; skip Helm installs (useful if
#                   you want to deploy manually or iterate on values).
set -euo pipefail

CLUSTER=open5gs
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIND_CONFIG="$SCRIPT_DIR/kind/kind-config.yaml"

SKIP_DEPLOY=false
[[ "${1:-}" == "--skip-deploy" ]] && SKIP_DEPLOY=true

# --- 1. Fix Docker iptables chains if missing (Docker 29 nftables bug) --------
# Use sudo -n (non-interactive) so the check never hangs waiting for a password
# when running in background. Silently skip if sudo requires a password.
echo "[1/5] Checking Docker iptables chains..."
if sudo -n iptables -t filter -L DOCKER-ISOLATION-STAGE-2 &>/dev/null 2>&1; then
  echo "  -> OK"
elif sudo -n iptables -t filter -N DOCKER-ISOLATION-STAGE-1 2>/dev/null && \
     sudo -n iptables -t filter -N DOCKER-ISOLATION-STAGE-2 2>/dev/null; then
  echo "  -> Created"
else
  echo "  -> Skipped (sudo password required — chains managed by Docker)"
fi

# --- 2. Tear down any existing cluster and recreate ---------------------------
echo "[2/5] Recreating kind cluster '$CLUSTER'..."
kind delete cluster --name "$CLUSTER" 2>/dev/null || true
kind create cluster --config "$KIND_CONFIG"
echo "  -> Cluster created"
kubectl get nodes

echo "  [2b] Preloading cached images into kind (avoids Docker Hub rate limits)..."
bash "$SCRIPT_DIR/kind/preload-images.sh" "$CLUSTER"

# --- 3. Raise inotify limits (required for Promtail + Chaos Mesh controller) --
echo "[3/5] Checking inotify limits..."
INSTANCES=$(sysctl -n fs.inotify.max_user_instances)
WATCHES=$(sysctl -n fs.inotify.max_user_watches)
if [[ "$INSTANCES" -lt 512 || "$WATCHES" -lt 524288 ]]; then
  echo "  -> Raising limits (current: instances=$INSTANCES watches=$WATCHES)..."
  sudo -n sysctl fs.inotify.max_user_instances=512 2>/dev/null || true
  sudo -n sysctl fs.inotify.max_user_watches=524288 2>/dev/null || true
else
  echo "  -> OK (instances=$INSTANCES watches=$WATCHES)"
fi

# --- 4. Deploy full stack (unless --skip-deploy) ------------------------------
if $SKIP_DEPLOY; then
  echo "[4/5] Skipping deploy (--skip-deploy)"
else
  echo "[4/5] Deploying full stack..."

  # ── Open5GS ────────────────────────────────────────────────────────────────
  echo "  [4a] Open5GS..."
  kubectl create namespace open5gs --dry-run=client -o yaml | kubectl apply -f -
  OPEN5GS_CHART="${OPEN5GS_CHART:-$SCRIPT_DIR/kind/charts/open5gs-2.3.4.tgz}"
  if [[ ! -f "$OPEN5GS_CHART" ]]; then
    OPEN5GS_CHART="${HOME}/.cache/helm/repository/open5gs-2.3.4.tgz"
  fi
  if [[ ! -f "$OPEN5GS_CHART" ]]; then
    mkdir -p "$SCRIPT_DIR/kind/charts"
    for attempt in 1 2 3 4 5; do
      if helm pull oci://registry-1.docker.io/gradiantcharts/open5gs \
          --version 2.3.4 -d "$SCRIPT_DIR/kind/charts" 2>/dev/null; then
        OPEN5GS_CHART="$SCRIPT_DIR/kind/charts/open5gs-2.3.4.tgz"
        break
      fi
      echo "  [WARN] helm pull open5gs attempt $attempt failed — waiting 60s..."
      sleep 60
    done
  fi
  _helm_open5gs() {
    helm install open5gs "$OPEN5GS_CHART" \
      --namespace open5gs \
      -f "$SCRIPT_DIR/kind/open5gs-values.yaml" \
      --wait --timeout=15m
  }
  if ! _helm_open5gs; then
    echo "  [WARN] Open5GS helm install failed — retrying once..."
    helm uninstall open5gs -n open5gs 2>/dev/null || true
    sleep 10
    _helm_open5gs
  fi

  # ── UERANSIM ───────────────────────────────────────────────────────────────
  echo "  [4b] UERANSIM gNB + UEs..."
  UERANSIM_CHART="${UERANSIM_CHART:-${HOME}/.cache/helm/repository/ueransim-gnb-0.2.6.tgz}"
  if [[ ! -f "$UERANSIM_CHART" ]]; then
    mkdir -p "$SCRIPT_DIR/kind/charts"
    helm pull oci://registry-1.docker.io/gradiant/ueransim-gnb \
      --version 0.2.6 -d "$SCRIPT_DIR/kind/charts" 2>/dev/null || true
    UERANSIM_CHART="$SCRIPT_DIR/kind/charts/ueransim-gnb-0.2.6.tgz"
  fi
  helm install ueransim-gnb "$UERANSIM_CHART" \
    --namespace open5gs \
    --values https://gradiant.github.io/5g-charts/docs/open5gs-ueransim-gnb/gnb-ues-values.yaml \
    --wait --timeout=5m
  # Standalone ueransim-ues overlaps gnb-ues IMSIs when scale_ues() adds batch
  # releases — experiments provision UEs via scale_ues() instead.

  # ── Observability ──────────────────────────────────────────────────────────
  echo "  [4c] Observability stack..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo add grafana               https://grafana.github.io/helm-charts             2>/dev/null || true
  helm repo add jaegertracing         https://jaegertracing.github.io/helm-charts       2>/dev/null || true
  helm repo update

  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

  helm install kube-prom prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --set grafana.adminPassword=admin \
    --set prometheus.prometheusSpec.scrapeInterval=5s \
    --timeout=10m

  helm install loki grafana/loki-stack \
    --namespace monitoring \
    --set promtail.enabled=true \
    --set loki.persistence.enabled=false \
    --set grafana.enabled=false

  helm install jaeger jaegertracing/jaeger \
    --namespace monitoring \
    --set allInOne.enabled=true \
    --set storage.type=memory \
    --set agent.enabled=false --set collector.enabled=false --set query.enabled=false \
    --timeout=5m

  kubectl apply -f "$SCRIPT_DIR/kind/monitoring/beyla-daemonset.yaml"

  # ── Chaos Mesh ─────────────────────────────────────────────────────────────
  echo "  [4d] Chaos Mesh..."
  helm repo add chaos-mesh https://charts.chaos-mesh.org 2>/dev/null || true
  helm repo update
  helm install chaos-mesh chaos-mesh/chaos-mesh \
    --namespace chaos-mesh --create-namespace \
    --version 2.7.2 \
    --set chaosDaemon.runtime=containerd \
    --set chaosDaemon.socketPath=/run/containerd/containerd.sock

  echo "  -> Waiting for Chaos Mesh to be ready (non-blocking for experiments)..."
  kubectl rollout status deployment/chaos-controller-manager -n chaos-mesh --timeout=10m 2>/dev/null || true
  kubectl wait --for=condition=ready pod -n chaos-mesh -l app.kubernetes.io/instance=chaos-mesh --timeout=5m 2>/dev/null || true
fi

# --- 5. Sanity checks ---------------------------------------------------------
echo "[5/5] Sanity checks..."
echo "  Nodes:"
kubectl get nodes
echo "  open5gs pods:"
kubectl get pods -n open5gs
echo "  monitoring pods:"
kubectl get pods -n monitoring
echo "  chaos-mesh pods:"
kubectl get pods -n chaos-mesh

echo ""
echo "Cluster ready."
echo "  Port-forward Grafana:    kubectl port-forward -n monitoring deployment/kube-prom-grafana 3000:3000"
echo "  Port-forward Prometheus: kubectl port-forward -n monitoring svc/kube-prom-kube-prometheus-prometheus 9090:9090"
echo "  Port-forward Jaeger:     kubectl port-forward -n monitoring svc/jaeger 16686:16686"

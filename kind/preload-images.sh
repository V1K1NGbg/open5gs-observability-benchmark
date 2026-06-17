#!/usr/bin/env bash
# Load locally cached images into a kind cluster to avoid Docker Hub rate limits.
#
# Usage: bash kind/preload-images.sh [cluster_name]
set -euo pipefail

CLUSTER="${1:-open5gs}"

if ! command -v kind >/dev/null 2>&1; then
    echo "[preload] kind not found — skipping" >&2
    exit 0
fi

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    echo "[preload] kind cluster '$CLUSTER' not found — skipping" >&2
    exit 0
fi

# Images referenced by cluster-start.sh / experiment stack.
IMAGES=(
    gradiant/open5gs:2.7.5
    gradiant/open5gs-dbctl:0.10.3
    registry-1.docker.io/bitnami/mongodb:latest
    bitnami/mongodb:latest
    gradiant/ueransim:3.2.6
    grafana/loki:2.6.1
    grafana/promtail:3.5.1
    jaegertracing/jaeger:2.18.0
    ghcr.io/chaos-mesh/chaos-coredns:v0.2.6
    ghcr.io/chaos-mesh/chaos-daemon:v2.7.2
    ghcr.io/chaos-mesh/chaos-dashboard:v2.7.2
    ghcr.io/chaos-mesh/chaos-mesh:v2.7.2
    quay.io/prometheus/prometheus:v3.12.0-distroless
    quay.io/prometheus/prometheus:v3.11.3-distroless
    quay.io/prometheus/alertmanager:v0.32.1
    quay.io/prometheus-operator/prometheus-operator:v0.91.0
    quay.io/prometheus-operator/prometheus-operator:v0.90.1
    quay.io/prometheus-operator/prometheus-config-reloader:v0.91.0
    quay.io/prometheus-operator/prometheus-config-reloader:v0.90.1
    quay.io/prometheus/node-exporter:v1.11.1-distroless
)

loaded=0
NODES=$(docker ps --format '{{.Names}}' | grep "^${CLUSTER}-" || true)

_load_one() {
    local img="$1"
    if kind load docker-image "$img" --name "$CLUSTER" 2>/dev/null; then
        return 0
    fi
    # kind load can fail on multi-platform manifests; fall back to ctr import.
    for node in $NODES; do
        docker save "$img" | docker exec -i "$node" ctr -n k8s.io images import - >/dev/null 2>&1 || return 1
    done
    return 0
}

for img in "${IMAGES[@]}"; do
    if docker image inspect "$img" &>/dev/null; then
        echo "[preload] loading $img"
        if _load_one "$img"; then
            loaded=$((loaded + 1))
        else
            echo "[preload] WARN: failed to load $img (continuing)" >&2
        fi
    fi
done

echo "[preload] Loaded $loaded image(s) into kind cluster '$CLUSTER'"

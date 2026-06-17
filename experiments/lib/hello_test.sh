#!/usr/bin/env bash
# Quick 2-minute data-plane sanity check: ping UPF via uesimtun0.
#
# Usage: bash experiments/lib/hello_test.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

UPF="${UPF_ADDR:-10.45.0.1}"
DURATION="${DURATION:-120}"
INTERVAL="${INTERVAL:-1}"

echo "[hello_test] Pinging $UPF via uesimtun0 for ${DURATION}s (interval ${INTERVAL}s)"
kubectl exec -n open5gs deployment/ueransim-ues -- \
  ping -I uesimtun0 -i "$INTERVAL" -w "$DURATION" "$UPF"

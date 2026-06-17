#!/usr/bin/env bash
# collect_ue_rtt.sh
#
# Runs continuous ping from a UE pod through a uesimtun* interface to the UPF
# gateway (10.45.0.1). Captures per-second RTT and packet loss.
#
# Usage:
#   bash collect_ue_rtt.sh <duration_s> <out_file>

set -euo pipefail

DURATION="${1:-300}"
OUT_FILE="${2:-/tmp/ue_rtt.csv}"
UPF_GW="10.45.0.1"

# Find pod + interface where ping succeeds. Prefer gnb-ues over batch pods.
_find_ue_ping_target() {
    local pod iface _rtt
    for pod in $(kubectl get pods -n open5gs --no-headers 2>/dev/null \
            | grep "ueransim-gnb-ues" | grep " Running " | awk '{print $1}'); do
        for iface in $(kubectl exec -n open5gs "$pod" -- \
                sh -c 'ip link show 2>/dev/null | grep -oE "uesimtun[0-9]+" || true' 2>/dev/null); do
            _rtt=$(kubectl exec -n open5gs "$pod" -- \
                ping -I "$iface" -c 1 -W 3 "$UPF_GW" 2>/dev/null \
                | grep -oP 'time=\K[\d.]+' || echo "")
            if [[ -n "$_rtt" ]]; then
                echo "$pod $iface"
                return 0
            fi
        done
    done
    for pod in $(kubectl get pods -n open5gs --no-headers 2>/dev/null \
            | grep "ueransim-ues-batch" | grep " Running " | awk '{print $1}'); do
        for iface in $(kubectl exec -n open5gs "$pod" -- \
                sh -c 'ip link show 2>/dev/null | grep -oE "uesimtun[0-9]+" || true' 2>/dev/null); do
            _rtt=$(kubectl exec -n open5gs "$pod" -- \
                ping -I "$iface" -c 1 -W 3 "$UPF_GW" 2>/dev/null \
                | grep -oP 'time=\K[\d.]+' || echo "")
            if [[ -n "$_rtt" ]]; then
                echo "$pod $iface"
                return 0
            fi
        done
    done
    return 1
}

_target=$(_find_ue_ping_target || true)
UE_POD="${_target%% *}"
IFACE="${_target#* }"
[[ "$IFACE" == "$UE_POD" ]] && IFACE=""

if [[ -z "$UE_POD" || -z "$IFACE" ]]; then
    echo "  [ue_rtt] WARNING: no UE pod with working uesimtun ping found" >&2
    echo "timestamp_ms,rtt_ms,status" > "$OUT_FILE"
    exit 0
fi

echo "  [ue_rtt] starting ${DURATION}s RTT collection from $UE_POD via $IFACE -> $UPF_GW"
echo "timestamp_ms,rtt_ms,status" > "$OUT_FILE"

END=$(($(date +%s) + DURATION))
while [[ $(date +%s) -lt $END ]]; do
    LOOP_START=$(date +%s%3N)
    RESULT=$(kubectl exec -n open5gs "$UE_POD" -- \
        ping -I "$IFACE" -c 1 -W 2 "$UPF_GW" 2>/dev/null \
        | grep -oP 'time=\K[\d.]+' || echo "")
    if [[ -n "$RESULT" ]]; then
        echo "${LOOP_START},${RESULT},ok" >> "$OUT_FILE"
    else
        echo "${LOOP_START},,loss" >> "$OUT_FILE"
    fi
    ELAPSED_MS=$(( $(date +%s%3N) - LOOP_START ))
    if [[ "$ELAPSED_MS" -lt 1000 ]]; then
        sleep "$(python3 -c "print(max(0, (1000-${ELAPSED_MS})/1000))")"
    fi
done
echo "  [ue_rtt] collection complete → $OUT_FILE"

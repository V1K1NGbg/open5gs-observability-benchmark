#!/usr/bin/env bash
# health_check.sh
#
# Snapshot cluster and UE health. Called before and after each fault.
# Prints a human-readable summary and optionally writes JSON to a file.
#
# Usage:
#   bash health_check.sh [label] [out_file.json]
#   label    - e.g. "pre-fault-01" or "post-fault-01"
#   out_file - optional JSON output path

set +e  # diagnostic script — don't abort on individual check failures

LABEL="${1:-check}"
OUT_FILE="${2:-}"

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo ""
echo "  ── health check: $LABEL @ $TS ──"

# Critical NFs whose absence aborts the run
CRITICAL_NFS=(amf smf upf nrf)

# ── 1. Pod health ──────────────────────────────────────────────────────────
TOTAL=$(kubectl get pods -n open5gs --no-headers 2>/dev/null | wc -l)
NOT_RUNNING=$(kubectl get pods -n open5gs --no-headers 2>/dev/null \
    | { grep -v " Running " || true; } | wc -l)
RESTARTS=$(kubectl get pods -n open5gs --no-headers 2>/dev/null \
    | awk '{sum+=$4} END{print sum+0}')

CRITICAL_DOWN=()
for nf in "${CRITICAL_NFS[@]}"; do
    state=$(kubectl get pods -n open5gs --no-headers 2>/dev/null \
        | grep "open5gs-${nf}-" | awk '{print $3}' | head -1)
    [[ "$state" != "Running" ]] && CRITICAL_DOWN+=("$nf($state)")
done

if [[ "${#CRITICAL_DOWN[@]}" -gt 0 ]]; then
    echo "  [pods]  CRITICAL — core NF(s) not Running: ${CRITICAL_DOWN[*]}"
elif [[ "$NOT_RUNNING" -eq 0 ]]; then
    echo "  [pods]  OK — ${TOTAL} pods running, total restarts=${RESTARTS}"
else
    echo "  [pods]  WARN — ${NOT_RUNNING}/${TOTAL} pods not Running (non-critical), total restarts=${RESTARTS}"
    kubectl get pods -n open5gs --no-headers 2>/dev/null | { grep -v " Running " || true; } | awk '{print "    !!", $1, $3, $4}'
fi

# ── 2. gNB → AMF connection ────────────────────────────────────────────────
# Poll up to 120s for NG Setup to complete (gNB may still be booting after cluster reset)
GNB_CONNECTED=0
echo -n "  [gnb]   waiting for NG Setup"
_gnb_deadline=$(( $(date +%s) + 120 ))
while true; do
    if kubectl logs -n open5gs deployment/ueransim-gnb 2>/dev/null \
            | grep -q "NG Setup procedure is successful"; then
        GNB_CONNECTED=1
        break
    fi
    [[ $(date +%s) -ge $_gnb_deadline ]] && break
    echo -n "."
    sleep 5
done
echo ""
if [[ "$GNB_CONNECTED" -eq 1 ]]; then
    if kubectl logs -n open5gs deployment/ueransim-gnb --tail=50 2>/dev/null \
            | grep -q "AMF selection.*failed"; then
        echo "  [gnb]   WARN — gNB connected but recent AMF selection failures"
    else
        echo "  [gnb]   OK — gNB connected to AMF"
    fi
else
    echo "  [gnb]   FAIL — gNB has no successful NG Setup in logs"
fi

# ── 3. UE tunnel count ─────────────────────────────────────────────────────
# UEs need time after pod Running to complete 5G registration + PDU session.
# Poll up to 240s so a slow-starting cluster (e.g. 100+ UEs after restart) doesn't cause a false abort.
echo -n "  [ues]   waiting for tunnels"
_tun_deadline=$(( $(date +%s) + 420 ))
while true; do
    # Sum tunnels across ALL UE pods (gnb-ues + batch releases from scale_ues)
    GNB_UE_TUNS=0
    UES_TUNS=0
    while IFS= read -r _pod; do
        [[ -z "$_pod" ]] && continue
        _tuns=$(kubectl exec -n open5gs "$_pod" -- \
            ip link show 2>/dev/null | { grep -c uesimtun || true; })
        _tuns=${_tuns:-0}
        if [[ "$_pod" == *ueransim-gnb-ues* ]]; then
            GNB_UE_TUNS=$(( GNB_UE_TUNS + _tuns ))
        else
            UES_TUNS=$(( UES_TUNS + _tuns ))
        fi
    done < <(kubectl get pods -n open5gs --no-headers 2>/dev/null \
        | grep -E "ueransim-gnb-ues|ueransim-ues-batch" | grep " Running " | awk '{print $1}')
    TOTAL_TUNS=$((GNB_UE_TUNS + UES_TUNS))
    [[ "$TOTAL_TUNS" -ge 5 ]] && break
    [[ $(date +%s) -ge $_tun_deadline ]] && break
    echo -n "."
    sleep 5
done
echo ""

if [[ "$TOTAL_TUNS" -ge 9 ]]; then
    echo "  [ues]   OK — ${TOTAL_TUNS} tunnels active (gnb-ues=${GNB_UE_TUNS} ueransim-ues=${UES_TUNS})"
elif [[ "$TOTAL_TUNS" -ge 1 ]]; then
    echo "  [ues]   WARN — only ${TOTAL_TUNS} tunnels active (gnb-ues=${GNB_UE_TUNS} ueransim-ues=${UES_TUNS})"
else
    echo "  [ues]   FAIL — no active UE tunnels"
fi

# ── 4. UDM subscription count ─────────────────────────────────────────────
UDM_SUBS=$(kubectl logs -n open5gs deployment/open5gs-udm --tail=500 2>/dev/null \
    | { grep -c "Maximum number of SDM Subscriptions" || true; })
if [[ "$UDM_SUBS" -gt 0 ]]; then
    echo "  [udm]   WARN — SDM subscription limit hit ${UDM_SUBS} time(s) in recent logs (transient during registration burst)"
else
    echo "  [udm]   OK — no SDM subscription overflow in recent logs"
fi

# ── 5. Quick data-plane ping ───────────────────────────────────────────────
UE_POD=""
RTT_OK=0
RTT=""
PING_IFACE=""
UPF_GW="10.45.0.1"
# Try each UE pod (gnb-ues + batch); use any uesimtun* interface (not only uesimtun0)
for pod in $(kubectl get pods -n open5gs --no-headers 2>/dev/null \
        | grep -E "ueransim-gnb-ues|ueransim-ues-batch" | grep " Running " | awk '{print $1}'); do
    _ifaces=$(kubectl exec -n open5gs "$pod" -- \
        sh -c 'ip link show 2>/dev/null | grep -oE "uesimtun[0-9]+" || true' 2>/dev/null || true)
    for _iface in $_ifaces; do
        for _rtt_try in 1 2 3; do
            RTT=$(kubectl exec -n open5gs "$pod" -- \
                ping -I "$_iface" -c 3 -W 3 "$UPF_GW" 2>/dev/null \
                | grep -oP 'rtt.*= \K[\d.]+' | cut -d/ -f2 || echo "")
            if [[ -n "$RTT" ]]; then
                UE_POD="$pod"
                PING_IFACE="$_iface"
                RTT_OK=1
                break 3
            fi
            sleep 10
        done
    done
done

if [[ "$RTT_OK" -eq 1 ]]; then
    echo "  [rtt]   OK — UPF ping avg=${RTT}ms via ${UE_POD} (${PING_IFACE})"
elif [[ -n "$UE_POD" ]]; then
    echo "  [rtt]   FAIL — ping to UPF ($UPF_GW) lost via ${UE_POD}"
else
    echo "  [rtt]   SKIP — no UE pod with working uesimtun ping found"
fi

echo "  ────────────────────────────────────────────────────"

# ── Optional JSON output ───────────────────────────────────────────────────
if [[ -n "$OUT_FILE" ]]; then
    mkdir -p "$(dirname "$OUT_FILE")"
    cat > "$OUT_FILE" <<EOF
{
  "label": "$LABEL",
  "timestamp": "$TS",
  "pods_total": $TOTAL,
  "pods_not_running": $NOT_RUNNING,
  "pod_restarts_total": $RESTARTS,
  "gnb_connected": $GNB_CONNECTED,
  "tunnels_gnb_ues": $GNB_UE_TUNS,
  "tunnels_ueransim_ues": $UES_TUNS,
  "tunnels_total": $TOTAL_TUNS,
  "udm_overflow_count": $UDM_SUBS,
  "rtt_avg_ms": "${RTT:-null}"
}
EOF
fi

# ── Abort on any critical failure ─────────────────────────────────────────
FAILURES=()
[[ "${#CRITICAL_DOWN[@]}" -gt 0 ]] && FAILURES+=("core NF(s) down: ${CRITICAL_DOWN[*]}")
[[ "$GNB_CONNECTED" -eq 0 ]]       && FAILURES+=("gNB not connected to AMF")
_MIN_TUNNELS="${MIN_TUNNELS:-10}"
[[ "$TOTAL_TUNS" -lt "$_MIN_TUNNELS" ]] && FAILURES+=("only ${TOTAL_TUNS} UE tunnels active (need ≥${_MIN_TUNNELS})")
[[ "$UDM_SUBS" -gt 0 ]]            && FAILURES+=("UDM subscription overflow")
[[ "${RTT_OK:-0}" -eq 0 ]]         && FAILURES+=("data-plane ping to UPF (10.45.0.1) failed — baseline would be on a dead data plane")

if [[ "${#FAILURES[@]}" -gt 0 ]]; then
    echo "  [health] CRITICAL: ${FAILURES[*]}" >&2
    exit 1
fi

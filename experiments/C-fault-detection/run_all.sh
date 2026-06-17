#!/usr/bin/env bash
# C-fault-detection/run_all.sh
#
# Phase 3: Fault detection — runs all 22 faults in sequence.
#
# Each fault: PRE phase -> fault phase -> POST phase, with full
# Prometheus + Jaeger + Loki + K8s events + NRF API + RTT collection.
#
# Durations are env-overridable:
#   PRE_DURATION    (default 600s)
#   FAULT_DURATION  (default 300s)
#   POST_DURATION   (default 300s)
#
# Usage:
#   bash run_all.sh [--from N]          # skip faults 1..N-1
#   bash run_all.sh --only 19,20        # run only the listed fault numbers

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/reset_workload.sh"

FROM=1
ONLY=""
while [[ $# -gt 0 ]]; do
    case "${1:-}" in
        --from) FROM="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        *) shift ;;
    esac
done

PRE_DURATION="${PRE_DURATION:-600}"
FAULT_DURATION="${FAULT_DURATION:-300}"
POST_DURATION="${POST_DURATION:-300}"

# Reset between faults is disabled: the post-phase (300s) + cooldown (60s) +
# pre-phase (600s) = 960s of recovery time is sufficient for all faults to
# self-heal via Kubernetes restart policies and PFCP/NRF heartbeats.
RESET_BETWEEN_FAULTS="${RESET_BETWEEN_FAULTS:-0}"

UE_COUNT="${UE_COUNT:-10}"
OUT_BASE="$DATA_DIR/C-fault-detection"

echo "============================================================"
echo " Phase 3: Fault detection (22 faults)"
echo " durations: pre=${PRE_DURATION}s  fault=${FAULT_DURATION}s  post=${POST_DURATION}s"
echo "============================================================"

echo "[setup] Checking Docker iptables chains (once per session)..."
if sudo -n iptables -t filter -L DOCKER-ISOLATION-STAGE-2 &>/dev/null 2>&1; then
    echo "  -> OK"
elif sudo -n iptables -t filter -N DOCKER-ISOLATION-STAGE-1 2>/dev/null && \
     sudo -n iptables -t filter -N DOCKER-ISOLATION-STAGE-2 2>/dev/null; then
    echo "  -> Created"
else
    echo "  -> Skipped (sudo password required — chains managed by Docker)"
fi

restart_ues() {
    # Always restart the gNB to clear stale GTP session state. Without this,
    # restarted UE pods re-register but the gNB's GTP table mismatches the
    # new PDU session TEIDs, causing "PDU session not found" uplink failures.
    echo "  [ue-restart] Restarting gNB for clean GTP state..."
    kubectl rollout restart deployment/ueransim-gnb -n open5gs
    kubectl rollout status deployment/ueransim-gnb -n open5gs --timeout=90s
    # Wait for old gNB pod to terminate so DNS resolves to the new pod IP
    local gnb_term_pods
    gnb_term_pods=$(kubectl get pods -n open5gs --no-headers 2>/dev/null \
        | awk '/ueransim-gnb-/ && /Terminating/{print $1}')
    if [[ -n "$gnb_term_pods" ]]; then
        # shellcheck disable=SC2086
        kubectl wait pod -n open5gs $gnb_term_pods --for=delete --timeout=60s 2>/dev/null || true
    fi
    # Wait for gNB to connect to AMF before starting UEs
    local amf_deadline=$(($(date +%s) + 60))
    until kubectl logs -n open5gs deployment/ueransim-gnb 2>/dev/null \
            | grep -q "NG Setup procedure is successful"; do
        [[ $(date +%s) -gt $amf_deadline ]] && { echo "  [ue-restart] WARNING: gNB did not connect to AMF within 60s"; break; }
        sleep 3
    done

    echo "  [ue-restart] Restarting UE pods for clean tunnel state..."
    kubectl rollout restart deployment/ueransim-gnb-ues deployment/ueransim-ues -n open5gs
    kubectl rollout status deployment/ueransim-gnb-ues -n open5gs --timeout=90s
    kubectl rollout status deployment/ueransim-ues -n open5gs --timeout=90s

    # Wait for old pods to finish terminating before declaring ready
    TERM_PODS=$(kubectl get pods -n open5gs --no-headers 2>/dev/null | awk '/Terminating/{print $1}')
    if [[ -n "$TERM_PODS" ]]; then
        echo "  [ue-restart] Waiting for terminating pods to clear..."
        # shellcheck disable=SC2086
        kubectl wait pod -n open5gs $TERM_PODS --for=delete --timeout=180s 2>/dev/null || {
            echo "  [ue-restart] ERROR: pods still Terminating after 3 minutes" >&2
            exit 1
        }
    fi

    # Wait for UE tunnels to appear (rollout status only means pod Running, not
    # that UE registration completed). Poll gnb-ues for ≥2 tunnels, 120s max.
    echo "  [ue-restart] Waiting for UE tunnels to appear..."
    local gnb_ue_pod tunnel_deadline tun_count
    gnb_ue_pod=$(kubectl get pods -n open5gs -l app.kubernetes.io/name=ueransim-gnb \
        --no-headers 2>/dev/null | grep gnb-ues | awk '{print $1}' | head -1)
    tunnel_deadline=$(($(date +%s) + 120))
    tun_count=0
    while [[ $(date +%s) -lt $tunnel_deadline ]]; do
        if [[ -n "$gnb_ue_pod" ]]; then
            tun_count=$(kubectl exec -n open5gs "$gnb_ue_pod" -- \
                ip link show 2>/dev/null | grep -c uesimtun || true)
        fi
        [[ "${tun_count:-0}" -ge 2 ]] && break
        sleep 5
    done
    echo "  [ue-restart] gnb-ues tunnels after wait: ${tun_count:-0}"

    # Add missing routes for the UPF data-plane gateway on all uesimtun
    # interfaces. UERANSIM assigns the /32 UE IP but does not add a route
    # for 10.45.0.1, so pings would fail without this.
    local ue_pod
    ue_pod=$(kubectl get pods -n open5gs -l app.kubernetes.io/component=ues \
        --no-headers 2>/dev/null | awk '{print $1}' | head -1)
    if [[ -n "$ue_pod" ]]; then
        kubectl exec -n open5gs "$ue_pod" -- bash -c '
            for i in $(seq 0 9); do
                ip link show uesimtun$i >/dev/null 2>&1 || continue
                ip route add 10.45.0.1 dev uesimtun$i 2>/dev/null || true
            done
        ' 2>/dev/null || true
        if kubectl exec -n open5gs "$ue_pod" -- \
                ping -I uesimtun0 -c 1 -W 2 10.45.0.1 >/dev/null 2>&1; then
            echo "  [ue-restart] Data-plane ready (ping OK via $ue_pod)"
        else
            echo "  [ue-restart] WARNING: data-plane ping still failing after route add"
        fi
    fi
}

# Full cluster bring-up for one fault: recreate + provision + portforwards +
# wait for all 10 UE tunnels. Used for the initial per-fault recreate and for
# the recreate-escalation when the pre-fault health check won't recover.
bring_up_cluster() {
    echo "[reset] Full cluster restart..."
    bash "$SCRIPT_DIR/../../cluster-start.sh"
    bash "$LIB_DIR/provision_ues.sh" "$UE_COUNT"
    ensure_portforward_prometheus
    ensure_portforward_jaeger
    ensure_portforward_loki
    echo "  [reset] Waiting for all ${UE_COUNT} gnb-ues tunnels (180s max)..."
    local gnb_ue_pod_reset tun_count_reset tun_deadline_reset
    gnb_ue_pod_reset=$(kubectl get pods -n open5gs -l app.kubernetes.io/name=ueransim-gnb \
        --no-headers 2>/dev/null | grep gnb-ues | awk '{print $1}' | head -1)
    tun_deadline_reset=$(($(date +%s) + 180))
    tun_count_reset=0
    while [[ $(date +%s) -lt $tun_deadline_reset ]]; do
        if [[ -n "$gnb_ue_pod_reset" ]]; then
            tun_count_reset=$(kubectl exec -n open5gs "$gnb_ue_pod_reset" -- \
                ip link show 2>/dev/null | grep -c uesimtun || true)
        fi
        [[ "${tun_count_reset:-0}" -ge "$UE_COUNT" ]] && break
        sleep 5
    done
    echo "  [reset] gnb-ues tunnels: ${tun_count_reset:-0}/${UE_COUNT}"
    # Add the UPF data-plane route on EVERY pod that has uesimtun interfaces.
    # UEs land on the gnb-ues pod OR the ueransim-ues pod depending on the
    # recreate; adding the route to only one (old behaviour) leaves the pinging
    # pod routeless -> RTT fails and the baseline is collected on a dead data
    # plane. Then ping-test the gnb-ues pod (the one traffic/RTT actually use).
    local p
    for p in "$gnb_ue_pod_reset" \
             $(kubectl get pods -n open5gs -l app.kubernetes.io/component=ues \
                 --no-headers 2>/dev/null | awk '{print $1}'); do
        [[ -n "$p" ]] || continue
        kubectl exec -n open5gs "$p" -- bash -c '
            for i in $(seq 0 9); do
                ip link show uesimtun$i >/dev/null 2>&1 || continue
                ip route add 10.45.0.1 dev uesimtun$i 2>/dev/null || true
            done
        ' 2>/dev/null || true
    done
    if [[ -n "$gnb_ue_pod_reset" ]] && kubectl exec -n open5gs "$gnb_ue_pod_reset" -- \
            ping -I uesimtun0 -c 1 -W 2 10.45.0.1 >/dev/null 2>&1; then
        echo "  [reset] Data-plane ready (ping OK via $gnb_ue_pod_reset)"
    else
        echo "  [reset] WARN — data-plane ping not OK; health check will gate it"
    fi
}

run_fault_experiment() {
    local num="$1" name="$2" manifest="$3"
    if [[ -n "$ONLY" ]] && ! echo ",$ONLY," | grep -q ",$num,"; then
        echo "[skip] Fault $num ($name)"
        return
    fi
    if [[ -z "$ONLY" && $num -lt $FROM ]]; then
        echo "[skip] Fault $num ($name)"
        return
    fi
    echo ""
    echo "------------------------------------------------------------"
    echo " Fault $num: $name"
    echo "------------------------------------------------------------"
    echo "[reset] Bringing up cluster for fault $num..."
    bring_up_cluster
    # Pre-fault health gate with escalation: re-check a few times (lets a slow
    # UE finish attaching), and only if it still won't pass do a full cluster
    # recreate. Abort the run only after recreates keep failing.
    local recreate_left=2 health_ok=0
    while :; do
        local h
        for h in 1 2 3; do
            if bash "$LIB_DIR/health_check.sh" "pre-${name}" \
                    "$OUT_BASE/${name}/health_pre.json"; then
                health_ok=1; break
            fi
            echo "  [gate] pre-fault health check failed (retry $h/3) —" \
                 "waiting 30s for UEs to settle..."
            sleep 30
        done
        [[ "$health_ok" -eq 1 ]] && break
        if [[ "$recreate_left" -le 0 ]]; then
            echo "[ABORT] health check still failing after recreates for fault $num ($name)" >&2
            echo "[ABORT] Re-run with: --from $num" >&2
            exit 1
        fi
        echo "  [gate] health unrecovered — full cluster recreate" \
             "(${recreate_left} recreate(s) left)..."
        recreate_left=$((recreate_left - 1))
        bring_up_cluster
    done
    bash "$LIB_DIR/run_fault.sh" \
        --name        "$name" \
        --manifest    "$CHAOS_DIR/$manifest" \
        --out         "$OUT_BASE/$name" \
        --pre-duration   "$PRE_DURATION" \
        --fault-duration "$FAULT_DURATION" \
        --post-duration  "$POST_DURATION" \
        --step           "5s"
    bash "$LIB_DIR/health_check.sh" "post-${name}" "$OUT_BASE/${name}/health_post.json" || true
}

# Slug == chaos YAML basename, so lib/hooks/<slug>.sh resolves automatically.
run_fault_experiment 1  "01-cpu-stress-amf"                        "01-cpu-stress-amf.yaml"
run_fault_experiment 2  "02-memory-pressure-upf"                   "02-memory-pressure-upf.yaml"
run_fault_experiment 3  "03-pod-crash-amf"                         "03-pod-crash-amf.yaml"
run_fault_experiment 4  "04-network-delay-gnb-amf"                 "04-network-delay-gnb-amf.yaml"
run_fault_experiment 5  "05-network-partition-amf-scp"             "05-network-partition-amf-scp.yaml"
run_fault_experiment 6  "06-packet-loss-upf"                       "06-packet-loss-upf.yaml"
run_fault_experiment 7  "07-pod-crash-smf"                         "07-pod-crash-smf.yaml"
run_fault_experiment 8  "08-cpu-stress-scp"                        "08-cpu-stress-scp.yaml"
run_fault_experiment 9  "09-network-delay-nrf"                     "09-network-delay-nrf.yaml"
run_fault_experiment 10 "10-pfcp-session-establishment-flood-upf"  "10-pfcp-session-establishment-flood-upf.yaml"
run_fault_experiment 11 "11-pfcp-session-deletion-upf"             "11-pfcp-session-deletion-upf.yaml"
run_fault_experiment 12 "12-pfcp-session-modification-drop-upf"    "12-pfcp-session-modification-drop-upf.yaml"
run_fault_experiment 13 "13-pfcp-session-modification-dupl-upf"    "13-pfcp-session-modification-dupl-upf.yaml"
run_fault_experiment 14 "14-upf-infrastructure-packet-loss"        "14-upf-infrastructure-packet-loss.yaml"
run_fault_experiment 15 "15-nrf-cascade"                           "15-nrf-cascade.yaml"
run_fault_experiment 16 "16-cpu-stress-ausf"                       "16-cpu-stress-ausf.yaml"
run_fault_experiment 17 "17-network-delay-scp"                     "17-network-delay-scp.yaml"
run_fault_experiment 18 "18-cpu-stress-nrf"                        "18-cpu-stress-nrf.yaml"
run_fault_experiment 19 "19-udm-pod-crash"                         "19-udm-pod-crash.yaml"
run_fault_experiment 20 "20-mongodb-pod-kill"                      "20-mongodb-pod-kill.yaml"
run_fault_experiment 21 "21-n2-partition-amf-gnb"                  "21-n2-partition-amf-gnb.yaml"
run_fault_experiment 22 "22-memory-pressure-amf"                   "22-memory-pressure-amf.yaml"

echo ""
echo "============================================================"
echo " Phase 3 complete. Data in: $OUT_BASE"
echo "============================================================"
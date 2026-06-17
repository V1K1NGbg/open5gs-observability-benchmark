#!/usr/bin/env bash
# experiments/lib/traffic.sh
#
# Synthetic traffic generation for fault-injection runs.
# Ported from experiments/run_experiment.sh (Boyan's main pipeline).
#
# Source this file then call start_traffic / stop_traffic.
# Without traffic, faults often produce no observable signal.
#
#   Data plane:    10 parallel pings via uesimtun0..9 -> 10.45.0.1 (UPF ogstun)
#                  at 5 pings/s each, exercising the GTP tunnel.
#   Control plane: 8 UEs deregister/register every 15s exercising the full
#                  NGAP + AMF + AUSF + UDM + NRF + SCP chain.

UE_POD=""
REREGISTER_PID=""

# All 10 UEs (imsi-999700000000001 .. 010) — the full set behind uesimtun0..9.
ALL_UES=()
for _n in $(seq 1 10); do
    ALL_UES+=("imsi-999700000000$(printf '%03d' "$_n")")
done

# _find_ue_pod — returns the name of the UE pod that has active uesimtun
# interfaces. Falls back to any pod matching 'ues' in its name.
_find_ue_pod() {
    # Prefer the pod that actually has uesimtun interfaces (gnb-ues after
    # ueransim-gnb is upgraded to 10 UEs). Iterate all pods with component=ues
    # and pick the first one with at least one uesimtun interface up.
    local candidates
    candidates=$(kubectl get pods -n open5gs -l app.kubernetes.io/component=ues \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    for pod in $candidates; do
        if kubectl exec -n open5gs "$pod" -- \
                ip link show uesimtun0 >/dev/null 2>&1; then
            echo "$pod"
            return 0
        fi
    done
    # Fallback: first pod with 'ues' in its name
    kubectl get pods -n open5gs --no-headers 2>/dev/null \
        | grep -m1 ues | awk '{print $1}' || true
}

# start_traffic — starts both loops in background.
# Caller is responsible for invoking stop_traffic on exit.
start_traffic() {
    UE_POD=$(_find_ue_pod)
    if [[ -z "$UE_POD" ]]; then
        echo "[traffic] WARNING: no UE pod found — traffic generation skipped" >&2
        return 0
    fi
    echo "[traffic] UE pod: $UE_POD"

    # 1. Data plane: continuous pings, 5/s per tunnel, to the UPF ogstun
    # gateway (10.45.0.1) — enough GTP traffic for PFCP signals to show.
    # IMPORTANT: ping ONLY the 7 stable UEs (uesimtun 0,1,5,6,7,8,9). The 3
    # UEs the control-plane loop deregisters/re-registers (imsi-…003/004/005 =
    # uesimtun 2,3,4) are deliberately EXCLUDED: a re-register that brings the
    # tunnel back up before its UPF PFCP session re-establishes is an orphaned
    # bearer; pinging it would flood 'Send Error Indication' for the rest of
    # the PRE window and contaminate the baseline (the 7/22 contamination).
    # Not pinging the churned UEs makes that contamination structurally
    # impossible. Keep this index set disjoint from the control-plane UEs below.
    kubectl exec -n open5gs "$UE_POD" -- bash -c '
        for i in 0 1 5 6 7 8 9; do
            ip link show uesimtun$i >/dev/null 2>&1 && \
                ping -i 0.2 -W 1 -I uesimtun$i 10.45.0.1 >/dev/null 2>&1 &
        done
        wait
    ' >/dev/null 2>&1 &
    echo "[traffic] data-plane pings started (stable UEs uesimtun 0,1,5-9)"

    # 2. Control plane: cycle 3 UEs (imsi-…003/004/005 = uesimtun 2,3,4, which
    # the data-plane loop above deliberately does NOT ping) through
    # deregister/register every ~70s. Generates AMF/AUSF/UDM/NRF signal without
    # its churn ever producing a pinged orphaned bearer.
    (
        UEs=("imsi-999700000000003" "imsi-999700000000004" "imsi-999700000000005")
        while true; do
            sleep 60
            for ue in "${UEs[@]}"; do
                kubectl exec -n open5gs "$UE_POD" -- \
                    nr-cli "$ue" --exec "deregister normal" 2>/dev/null || true
            done
            sleep 10
            for ue in "${UEs[@]}"; do
                kubectl exec -n open5gs "$UE_POD" -- \
                    nr-cli "$ue" --exec "register" 2>/dev/null || true
            done
        done
    ) &
    REREGISTER_PID=$!
    echo "[traffic] control-plane re-registration loop started (pid=$REREGISTER_PID)"
}

# repair_orphaned_bearers — clean re-attach of ALL UEs so every uesimtun the
# data-plane ping loop touches has a live UPF PFCP session. Fixes the
# orphaned-bearer condition (one UE PDU session lost at bring-up while its
# GTP-U tunnel persists -> UPF floods 'Send Error Indication'). Returns 0 only
# when all 10 tunnels are back up.
repair_orphaned_bearers() {
    [[ -z "${UE_POD:-}" ]] && UE_POD=$(_find_ue_pod)
    if [[ -z "$UE_POD" ]]; then
        echo "[repair] no UE pod found — cannot repair bearers" >&2
        return 1
    fi
    echo "[repair] clean re-attach of all ${#ALL_UES[@]} UEs..."
    for ue in "${ALL_UES[@]}"; do
        kubectl exec -n open5gs "$UE_POD" -- \
            nr-cli "$ue" --exec "deregister normal" 2>/dev/null || true
    done
    sleep 10
    for ue in "${ALL_UES[@]}"; do
        kubectl exec -n open5gs "$UE_POD" -- \
            nr-cli "$ue" --exec "register" 2>/dev/null || true
    done
    # Wait up to ~60s for all 10 uesimtun interfaces to come back up.
    local up=0 _i
    for _i in $(seq 1 30); do
        up=$(kubectl exec -n open5gs "$UE_POD" -- bash -c \
            'c=0; for i in $(seq 0 9); do ip link show uesimtun$i >/dev/null 2>&1 && c=$((c+1)); done; echo $c' \
            2>/dev/null || echo 0)
        if [[ "$up" == "10" ]]; then
            echo "[repair] all 10 tunnels up"
            return 0
        fi
        sleep 2
    done
    echo "[repair] WARNING: only $up/10 tunnels recovered" >&2
    return 1
}

# stop_traffic — kills both loops; safe to call multiple times.
stop_traffic() {
    [[ -n "${REREGISTER_PID:-}" ]] && kill "$REREGISTER_PID" 2>/dev/null || true
    if [[ -n "${UE_POD:-}" ]]; then
        kubectl exec -n open5gs "$UE_POD" -- \
            bash -c 'pkill ping 2>/dev/null; true' 2>/dev/null || true
    fi
}

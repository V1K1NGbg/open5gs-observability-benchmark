#!/usr/bin/env bash
# experiments/lib/reset_workload.sh
#
# Soft-reset the open5gs workload between fault experiments.
# Restarts pods in dependency order to clear stale state (PFCP sessions,
# NF registrations, UE tunnels) without helm uninstall/reinstall.
# This avoids pod-IP churn that caused SCP→AUSF routing failures.
# MongoDB PVC is kept so subscriber provisioning is preserved.
#
# Costs ~60-90s per call (vs ~3min for the old helm approach).
#
# Caller is expected to source common.sh first so $LIB_DIR is set.
#
# Usage:
#   reset_workload      # UE count is fixed at 10 (set in helm upgrade)

reset_workload() {
    # 1. NRF first — all NFs register against a fresh NRF so SCP gets
    # current pod IPs, not stale ones from a previous run.
    echo "[reset] restarting NRF..."
    kubectl rollout restart deployment/open5gs-nrf -n open5gs
    kubectl rollout status  deployment/open5gs-nrf -n open5gs --timeout=60s

    # 2. All other NFs in parallel — they re-register with the fresh NRF.
    echo "[reset] restarting NFs..."
    kubectl rollout restart \
        deployment/open5gs-scp \
        deployment/open5gs-ausf \
        deployment/open5gs-udm \
        deployment/open5gs-udr \
        deployment/open5gs-amf \
        deployment/open5gs-smf \
        deployment/open5gs-upf \
        deployment/open5gs-pcf \
        deployment/open5gs-bsf \
        deployment/open5gs-nssf \
        -n open5gs
    for dep in scp ausf udm udr amf smf upf pcf bsf nssf; do
        kubectl rollout status deployment/open5gs-$dep -n open5gs --timeout=90s
    done

    # 3. Wait for NFs to fully register with NRF before touching gNB/UEs.
    # UERANSIM gNB does not auto-reconnect after SCTP drop, so it must start
    # only after AMF is fully up and accepting connections.
    echo "[reset] waiting for NF mesh to stabilise..."
    sleep 30

    # 4. gNB — reconnects to AMF with a fresh NGAP association.
    echo "[reset] restarting gNB..."
    kubectl rollout restart deployment/ueransim-gnb -n open5gs
    kubectl rollout status  deployment/ueransim-gnb -n open5gs --timeout=60s
    sleep 5

    # 5. UE pods — fresh registration + PDU session establishment.
    echo "[reset] restarting UEs..."
    kubectl rollout restart \
        deployment/ueransim-gnb-ues \
        deployment/ueransim-ues \
        -n open5gs
    kubectl rollout status deployment/ueransim-gnb-ues -n open5gs --timeout=60s
    kubectl rollout status deployment/ueransim-ues     -n open5gs --timeout=60s

    # 6. Wait for uesimtun0 to appear (PDU session established).
    echo "[reset] waiting for UE PDU sessions..."
    local ue_pod i=0
    ue_pod=$(kubectl get pods -n open5gs -l app.kubernetes.io/component=ues \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    while ! kubectl exec -n open5gs "$ue_pod" -- \
            ip link show uesimtun0 >/dev/null 2>&1; do
        sleep 3
        i=$((i + 3))
        if [[ $i -ge 90 ]]; then
            echo "[reset] WARN: uesimtun0 not up after 90s — UEs may need more time"
            break
        fi
    done

    local tun_count
    tun_count=$(kubectl exec -n open5gs "$ue_pod" -- \
        ip link show 2>/dev/null | grep -c uesimtun || true)
    echo "[reset] workload ready — ${tun_count}/10 UE tunnels up"
}

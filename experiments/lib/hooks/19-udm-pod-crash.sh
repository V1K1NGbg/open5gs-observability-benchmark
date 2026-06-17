#!/usr/bin/env bash
# Hook: 19-udm-pod-crash
#
# UDM is on the registration/authentication path (AUSF -> UDM -> UDR).
# With UEs already registered before the fault, the failure is invisible
# during steady-state traffic. Restart UEs at fault injection so new
# NAS registrations hit UDM while it is down, making the fault observable.

during_fault() {
    echo "  [hook 19] restarting UEs to trigger registrations against downed UDM..."
    kubectl rollout restart deployment/ueransim-gnb-ues -n open5gs
    # Don't wait for rollout status — UEs will fail to register (expected).
}

#!/usr/bin/env bash
# Hook: 07-pod-crash-smf
#
# SMF crash leaves stale PFCP session state on UPF. Restart SMF to
# clear it; without this, PDU sessions stay broken into the post window.

post_delete() {
    echo "  [hook 07] SMF killed — restarting to clear PFCP state..."
    kubectl rollout restart deployment/open5gs-smf -n open5gs
    kubectl rollout status  deployment/open5gs-smf -n open5gs --timeout=60s
    sleep 15
}

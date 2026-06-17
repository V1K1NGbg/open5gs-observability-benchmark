#!/usr/bin/env bash
# Hook: 20-mongodb-pod-kill
#
# MongoDB is only accessed on the registration path (UDR -> MongoDB).
# With UEs already registered, MongoDB is on the cold path and its failure
# is invisible during steady-state traffic. Restart UEs at fault injection
# so new NAS registrations hit UDR -> MongoDB while the database is down.

during_fault() {
    echo "  [hook 20] restarting UEs to trigger registrations against downed MongoDB..."
    kubectl rollout restart deployment/ueransim-gnb-ues -n open5gs
    # Don't wait for rollout status — UEs will fail to register (expected).
}

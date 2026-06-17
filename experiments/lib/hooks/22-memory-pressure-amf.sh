#!/usr/bin/env bash
# Hook: 22-memory-pressure-amf
#
# StressChaos allocates in chaos-daemon's cgroup, not inside the AMF
# container — so it won't hit AMF's 128Mi limit on its own. Allocate
# memory inside the AMF container to reliably trigger OOM kill.
#
# After OOM, AMF kill tears down the gNB SCTP link. Restart gNB and
# UEs so the N2 link re-establishes and traffic resumes in the post window.

during_fault() {
    local amf_pod
    amf_pod=$(kubectl get pods -n open5gs -l app.kubernetes.io/name=amf \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$amf_pod" ]]; then
        echo "  [hook 22] WARNING: AMF pod not found, skipping in-container alloc" >&2
        return 0
    fi
    echo "  [hook 22] allocating 150MB inside AMF ($amf_pod) to force OOM..."
    kubectl exec -n open5gs "$amf_pod" -c open5gs-amf -- \
        perl -e 'my $x = "a" x (150*1024*1024); print "allocated 150MB\n"; sleep 400' \
        >/dev/null 2>&1 &
}

post_delete() {
    echo "  [hook 22] AMF OOM killed — restarting gNB and UEs..."
    kubectl rollout restart deployment/ueransim-gnb -n open5gs
    kubectl rollout status  deployment/ueransim-gnb -n open5gs --timeout=60s
    kubectl rollout restart deployment/ueransim-gnb-ues -n open5gs
    kubectl rollout status  deployment/ueransim-gnb-ues -n open5gs --timeout=60s
    sleep 15
}

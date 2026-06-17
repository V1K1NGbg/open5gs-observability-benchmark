#!/usr/bin/env bash
# Hook: 03-pod-crash-amf
#
# AMF kill tears down the gNB SCTP link. Restart gNB and UEs so PDU
# sessions re-establish and synthetic traffic resumes.

post_delete() {
    echo "  [hook 03] AMF killed — restarting gNB and UEs..."
    kubectl rollout restart deployment/ueransim-gnb -n open5gs
    kubectl rollout status  deployment/ueransim-gnb -n open5gs --timeout=60s
    kubectl rollout restart deployment/ueransim-gnb-ues -n open5gs
    kubectl rollout status  deployment/ueransim-gnb-ues -n open5gs --timeout=60s
    sleep 15
}

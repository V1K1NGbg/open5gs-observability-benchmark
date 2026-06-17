#!/usr/bin/env bash
# Hook: 21-n2-partition-amf-gnb
#
# Partitioning the N2 link drops the NGAP SCTP connection. gNB won't
# reconnect automatically after the partition is removed — restart it
# and UEs so the N2 link re-establishes and traffic resumes.

during_fault() {
    local amf_pod gnb_ip out
    amf_pod=$(kubectl get pods -n open5gs -l app.kubernetes.io/name=amf \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    gnb_ip=$(kubectl get pods -n open5gs -l app.kubernetes.io/component=gnb \
        -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
    if [[ -z "$amf_pod" || -z "$gnb_ip" ]]; then
        echo "  [hook 21] WARNING: AMF pod or gNB IP not found, skipping connectivity check" >&2
        return 0
    fi
    out="$OUT_DIR/rtt/during/rtt_samples.txt"
    mkdir -p "$(dirname "$out")"
    echo "# Packet loss during N2 partition: AMF -> gNB" > "$out"
    (
        local ping_out
        ping_out=$(kubectl exec -n open5gs "$amf_pod" -c open5gs-amf -- \
            ping -i 1 -W 1 -c 10 "$gnb_ip" 2>/dev/null || true)
        echo "$ping_out" | grep -oP '\d+% packet loss' >> "$out" || true
    ) &
}

post_delete() {
    echo "  [hook 21] N2 partition removed — restarting gNB and UEs..."
    kubectl rollout restart deployment/ueransim-gnb -n open5gs
    kubectl rollout status  deployment/ueransim-gnb -n open5gs --timeout=60s
    kubectl rollout restart deployment/ueransim-gnb-ues -n open5gs
    kubectl rollout status  deployment/ueransim-gnb-ues -n open5gs --timeout=60s
    sleep 15
}

#!/usr/bin/env bash
# Hook: 05-network-partition-amf-scp
#
# Target is AMF<->SCP (Open5GS Model D indirect SBI: AMF never talks to
# NRF directly). 100% packet drop is invisible to Beyla; the only proof
# is a ping that comes back as "100% packet loss".

during_fault() {
    local amf_pod scp_ip out
    amf_pod=$(kubectl get pods -n open5gs -l app.kubernetes.io/name=amf \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    scp_ip=$(kubectl get pods -n open5gs -l app.kubernetes.io/name=scp \
        -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
    if [[ -z "$amf_pod" || -z "$scp_ip" ]]; then
        echo "  [hook 05] WARNING: AMF pod or SCP IP not found, skipping RTT" >&2
        return 0
    fi
    out="$OUT_DIR/rtt/during/rtt_samples.txt"
    mkdir -p "$(dirname "$out")"
    echo "# Packet loss during partition: AMF -> SCP" > "$out"
    (
        local ping_out
        ping_out=$(kubectl exec -n open5gs "$amf_pod" -c open5gs-amf -- \
            ping -i 1 -W 1 -c 10 "$scp_ip" 2>/dev/null || true)
        echo "$ping_out" | grep -oP '\d+% packet loss' >> "$out" || true
    ) &
}

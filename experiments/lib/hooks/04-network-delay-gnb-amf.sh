#!/usr/bin/env bash
# Hook: 04-network-delay-gnb-amf
#
# Chaos Mesh applies delay at the TC kernel layer. Beyla eBPF sits above
# TC and is blind to it, so Jaeger spans look unchanged. The only way to
# confirm the delay is to ping AMF -> SCP during the fault phase and
# parse the RTT samples.

during_fault() {
    local amf_pod scp_ip out
    amf_pod=$(kubectl get pods -n open5gs -l app.kubernetes.io/name=amf \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    scp_ip=$(kubectl get pods -n open5gs -l app.kubernetes.io/name=scp \
        -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
    if [[ -z "$amf_pod" || -z "$scp_ip" ]]; then
        echo "  [hook 04] WARNING: AMF pod or SCP IP not found, skipping RTT" >&2
        return 0
    fi
    out="$OUT_DIR/rtt/during/rtt_samples.txt"
    mkdir -p "$(dirname "$out")"
    echo "# RTT samples (ms): AMF -> SCP ping during fault phase" > "$out"
    (
        local ping_out
        ping_out=$(kubectl exec -n open5gs "$amf_pod" -c open5gs-amf -- \
            ping -i 1 -W 3 -c "$FAULT_DURATION" "$scp_ip" 2>/dev/null || true)
        echo "$ping_out" | grep -oP 'time=\K[\d.]+' >> "$out" || true
        echo "$ping_out" | grep -oP '\d+% packet loss' >> "$out" || true
    ) &
}

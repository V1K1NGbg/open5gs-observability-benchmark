#!/usr/bin/env bash
# Hook: 09-network-delay-nrf
#
# Same blind-spot as 04: TC-layer delay on NRF is invisible to Beyla.
# Ping AMF -> NRF directly during the fault phase to capture the RTT.

during_fault() {
    local amf_pod nrf_ip out
    amf_pod=$(kubectl get pods -n open5gs -l app.kubernetes.io/name=amf \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    nrf_ip=$(kubectl get pods -n open5gs -l app.kubernetes.io/name=nrf \
        -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
    if [[ -z "$amf_pod" || -z "$nrf_ip" ]]; then
        echo "  [hook 09] WARNING: AMF pod or NRF IP not found, skipping RTT" >&2
        return 0
    fi
    out="$OUT_DIR/rtt/during/rtt_samples.txt"
    mkdir -p "$(dirname "$out")"
    echo "# RTT samples (ms): AMF -> NRF ping during fault phase" > "$out"
    (
        local ping_out
        ping_out=$(kubectl exec -n open5gs "$amf_pod" -c open5gs-amf -- \
            ping -i 1 -W 3 -c "$FAULT_DURATION" "$nrf_ip" 2>/dev/null || true)
        echo "$ping_out" | grep -oP 'time=\K[\d.]+' >> "$out" || true
        echo "$ping_out" | grep -oP '\d+% packet loss' >> "$out" || true
    ) &
}

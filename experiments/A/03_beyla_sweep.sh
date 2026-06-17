#!/usr/bin/env bash
# A/03_beyla_sweep.sh
#
# Experiment 03 — eBPF / Beyla Sampling Rate Sweep
#
# Condition:
#   Open5GS NF metrics endpoints : DISABLED (isolate eBPF from app-layer metrics)
#   Prometheus server             : ENABLED — passive storage backend only
#   Beyla DaemonSet               : ENABLED — Active Subject Under Test
#
# Variables:
#   Sampling rates: 100%, 50%, 10%
#   Replications:   6 per rate
#
# Env overrides:
#   COLLECTION_DURATION  (default 300s)
#   UE_COUNT             (default 50)
#   REPLICATIONS         (default 6)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/configure_telemetry.sh"

COLLECTION_DURATION="${COLLECTION_DURATION:-300}"
UE_COUNT="${UE_COUNT:-50}"
REPLICATIONS="${REPLICATIONS:-6}"
OUT_BASE="$DATA_DIR/A/03-beyla-sweep"
MIN_TUNNELS=$(( UE_COUNT * 8 / 10 ))

SAMPLING_RATES=(100 50 10)

_BEYLA_EXTRA=(
    "beyla_cpu:rate(container_cpu_usage_seconds_total{namespace=\"open5gs\",pod=~\"beyla.*\",container=\"beyla\"}[2m]):beyla_cpu.csv"
    "beyla_mem:container_memory_working_set_bytes{namespace=\"open5gs\",pod=~\"beyla.*\",container=\"beyla\"}:beyla_mem.csv"
    "jaeger_cpu:rate(container_cpu_usage_seconds_total{namespace=\"monitoring\",pod=~\"jaeger.*\"}[2m]):jaeger_cpu.csv"
    "jaeger_mem:container_memory_working_set_bytes{namespace=\"monitoring\",pod=~\"jaeger.*\"}:jaeger_mem.csv"
    "prom_mem:process_resident_memory_bytes{job=\"kube-prom-kube-prometheus-prometheus\"}:prom_self_mem.csv"
    "beyla_http_req_rate:rate(http_server_request_duration_seconds_count{k8s_namespace_name=\"open5gs\"}[2m]):beyla_span_rate.csv"
    "beyla_http_dur_p99:histogram_quantile(0.99,rate(http_server_request_duration_seconds_bucket{k8s_namespace_name=\"open5gs\"}[2m])):beyla_http_p99.csv"
    "nf_cpu:rate(container_cpu_usage_seconds_total{namespace=\"open5gs\",container!=\"\",container!~\"POD|beyla.*\"}[2m]):nf_cpu.csv"
    "nf_mem:container_memory_working_set_bytes{namespace=\"open5gs\",container!=\"\",container!~\"POD|beyla.*\"}:nf_mem.csv"
)

echo "============================================================"
echo " Experiment 03 — eBPF / Beyla Sampling Rate Sweep"
echo " rates=${SAMPLING_RATES[*]}%  replications=${REPLICATIONS}"
echo " duration=${COLLECTION_DURATION}s  ues=${UE_COUNT}"
echo "============================================================"

check_cluster_ready

for RATE in "${SAMPLING_RATES[@]}"; do
    echo ""
    echo "------------------------------------------------------------"
    echo " Beyla sampling rate: ${RATE}%"
    echo "------------------------------------------------------------"

    for RUN in $(seq 1 "$REPLICATIONS"); do
        echo ""
        echo "  [run $RUN/$REPLICATIONS] rate=${RATE}%"
        OUT_DIR="$OUT_BASE/${RATE}pct/run_${RUN}"
        mkdir -p "$OUT_DIR"

        if [[ "${SKIP_VALID_RUNS:-1}" == "1" ]] && [[ -f "$OUT_DIR/meta.json" ]] && \
            python3 -c "import json,sys; d=json.load(open('$OUT_DIR/meta.json')); sys.exit(0 if d.get('data_valid') is True else 1)" 2>/dev/null; then
            echo "  [skip] $OUT_DIR — already valid"
            continue
        fi

        # ── Full cluster reset + UE scaling ──────────────────────────
        echo "  [reset] Full cluster restart..."
        setup_cluster_with_ues "$UE_COUNT"

        # ── Configure telemetry AFTER cluster is up ──────────────────
        disable_open5gs_metrics
        enable_prometheus_server
        enable_beyla
        set_beyla_sampling_rate "$RATE"

        ensure_portforward_prometheus
        ensure_portforward_jaeger

        wait_for_pods_stable open5gs 180
        echo "  [warmup] 30s Beyla warmup for eBPF program attachment..."
        sleep 30

        require_health_check "pre-beyla-${RATE}pct-run${RUN}" \
            "$OUT_DIR/health_pre.json" "$MIN_TUNNELS"

        log_experiment_start "03-beyla-${RATE}pct-run${RUN}" "$OUT_DIR"
        GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        python3 -c "
import json; d = json.load(open('$OUT_DIR/meta.json'))
d.update({'condition': '03-beyla-sweep',
          'beyla_sampling_rate_pct': $RATE,
          'run': $RUN,
          'replications': $REPLICATIONS,
          'ue_count': $UE_COUNT,
          'collection_duration_s': $COLLECTION_DURATION,
          'rate_warmup_s': $RATE_WARMUP_S,
          'git_sha': '$GIT_SHA',
          'prometheus_enabled': True,
          'beyla_enabled': True,
          'open5gs_metrics_enabled': False,
          'rtt_metric': 'data_plane_ping_ms',
          'note': 'Prometheus is passive storage only; open5gs NF metrics disabled'})
json.dump(d, open('$OUT_DIR/meta.json', 'w'), indent=2)
"
        START_TS=$(date +%s)

        bash "$LIB_DIR/collect_ue_rtt.sh" "$COLLECTION_DURATION" "$OUT_DIR/ue_rtt.csv" &
        RTT_PID=$!

        sleep_with_progress "$COLLECTION_DURATION" "collecting"

        wait "$RTT_PID" || { mark_run_invalid "$OUT_DIR" "rtt_collector_failed"; exit 1; }
        END_TS=$(date +%s)
        PROM_START=$(prom_query_start "$START_TS")

        collect_prometheus_extra "$PROM_START" "$END_TS" "5s" "$OUT_DIR/prometheus" \
            "${_BEYLA_EXTRA[@]}"

        collect_jaeger "$PROM_START" "$END_TS" "$OUT_DIR/jaeger"

        validate_required_metrics "$OUT_DIR" beyla_cpu.csv nf_cpu.csv || true
        validate_ue_rtt "$OUT_DIR" 0.5 && mark_run_valid "$OUT_DIR" || true

        python3 -c "
import json
d = json.load(open('$OUT_DIR/meta.json'))
d.update({'started_unix': $START_TS, 'ended_unix': $END_TS,
          'prom_query_start_unix': $PROM_START,
          'actual_duration_s': $END_TS - $START_TS})
json.dump(d, open('$OUT_DIR/meta.json', 'w'), indent=2)
"
        log_experiment_end "$OUT_DIR"
        require_health_check "post-beyla-${RATE}pct-run${RUN}" \
            "$OUT_DIR/health_post.json" "$MIN_TUNNELS" || true

        echo "  [run $RUN done] Data in: $OUT_DIR"
    done
done

enable_open5gs_metrics
set_beyla_sampling_rate 100

echo ""
echo "============================================================"
echo " Experiment 03 complete. Data in: $OUT_BASE"
echo "============================================================"

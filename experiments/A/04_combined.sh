#!/usr/bin/env bash
# A/04_combined.sh
#
# Experiment 04 — Combined Production Telemetry Baseline
#
# Condition:
#   Open5GS NF metrics endpoints : ENABLED
#   Prometheus server             : ENABLED (scrape interval: 5s)
#   Beyla DaemonSet               : ENABLED (sampling: 100%)
#
# Env overrides:
#   COLLECTION_DURATION  (default 300s)
#   UE_COUNT             (default 50)
#   ITERATIONS           (default 3)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/configure_telemetry.sh"

COLLECTION_DURATION="${COLLECTION_DURATION:-300}"
UE_COUNT="${UE_COUNT:-50}"
ITERATIONS="${ITERATIONS:-3}"
OUT_BASE="$DATA_DIR/A/04-combined"
MIN_TUNNELS=$(( UE_COUNT * 8 / 10 ))

_COMBINED_EXTRA=(
    "prom_cpu:rate(process_cpu_seconds_total{job=\"kube-prom-kube-prometheus-prometheus\"}[2m]):prom_self_cpu.csv"
    "prom_mem:process_resident_memory_bytes{job=\"kube-prom-kube-prometheus-prometheus\"}:prom_self_mem.csv"
    "beyla_cpu:rate(container_cpu_usage_seconds_total{namespace=\"open5gs\",pod=~\"beyla.*\",container=\"beyla\"}[2m]):beyla_cpu.csv"
    "beyla_mem:container_memory_working_set_bytes{namespace=\"open5gs\",pod=~\"beyla.*\",container=\"beyla\"}:beyla_mem.csv"
    "jaeger_cpu:rate(container_cpu_usage_seconds_total{namespace=\"monitoring\",pod=~\"jaeger.*\"}[2m]):jaeger_cpu.csv"
    "jaeger_mem:container_memory_working_set_bytes{namespace=\"monitoring\",pod=~\"jaeger.*\"}:jaeger_mem.csv"
    "nf_cpu:rate(container_cpu_usage_seconds_total{namespace=\"open5gs\",container!=\"\",container!~\"POD|beyla.*\"}[2m]):nf_cpu.csv"
    "nf_mem:container_memory_working_set_bytes{namespace=\"open5gs\",container!=\"\",container!~\"POD|beyla.*\"}:nf_mem.csv"
    "total_monitoring_cpu:rate(container_cpu_usage_seconds_total{namespace=\"monitoring\",container!=\"\"}[2m]):total_monitoring_cpu.csv"
    "total_monitoring_mem:container_memory_working_set_bytes{namespace=\"monitoring\",container!=\"\"}:total_monitoring_mem.csv"
)

echo "============================================================"
echo " Experiment 04 — Combined Production Telemetry Baseline"
echo " iterations=${ITERATIONS}  duration=${COLLECTION_DURATION}s  ues=${UE_COUNT}"
echo "============================================================"

check_cluster_ready

for RUN in $(seq 1 "$ITERATIONS"); do
    echo ""
    echo "------------------------------------------------------------"
    echo " Iteration $RUN/$ITERATIONS"
    echo "------------------------------------------------------------"
    OUT_DIR="$OUT_BASE/run_${RUN}"
    mkdir -p "$OUT_DIR"

    if [[ "${SKIP_VALID_RUNS:-1}" == "1" ]] && [[ -f "$OUT_DIR/meta.json" ]] && \
        python3 -c "import json,sys; d=json.load(open('$OUT_DIR/meta.json')); sys.exit(0 if d.get('data_valid') is True else 1)" 2>/dev/null; then
        echo "[skip] $OUT_DIR — already valid"
        continue
    fi

    setup_cluster_with_ues "$UE_COUNT"

    restore_production_telemetry
    set_prometheus_scrape_interval "5s"

    ensure_portforward_prometheus
    ensure_portforward_jaeger

    wait_for_pods_stable open5gs 180
    echo "[warmup] 45s combined stack warmup..."
    sleep 45

    require_health_check "pre-combined-run${RUN}" \
        "$OUT_DIR/health_pre.json" "$MIN_TUNNELS"

    log_experiment_start "04-combined-run${RUN}" "$OUT_DIR"
    GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    python3 -c "
import json; d = json.load(open('$OUT_DIR/meta.json'))
d.update({'condition': '04-combined-production',
          'scrape_interval': '5s',
          'beyla_sampling_rate_pct': 100,
          'run': $RUN,
          'iterations': $ITERATIONS,
          'ue_count': $UE_COUNT,
          'collection_duration_s': $COLLECTION_DURATION,
          'rate_warmup_s': $RATE_WARMUP_S,
          'git_sha': '$GIT_SHA',
          'prometheus_enabled': True,
          'beyla_enabled': True,
          'open5gs_metrics_enabled': True,
          'rtt_metric': 'data_plane_ping_ms'})
json.dump(d, open('$OUT_DIR/meta.json', 'w'), indent=2)
"
    START_TS=$(date +%s)

    bash "$LIB_DIR/collect_ue_rtt.sh" "$COLLECTION_DURATION" "$OUT_DIR/ue_rtt.csv" &
    RTT_PID=$!

    sleep_with_progress "$COLLECTION_DURATION" "collecting"

    wait "$RTT_PID" || { mark_run_invalid "$OUT_DIR" "rtt_collector_failed"; exit 1; }
    END_TS=$(date +%s)
    PROM_START=$(prom_query_start "$START_TS")

    collect_prometheus "$PROM_START" "$END_TS" "5s" "$OUT_DIR/prometheus"
    collect_prometheus_extra "$PROM_START" "$END_TS" "5s" "$OUT_DIR/prometheus" \
        "${_COMBINED_EXTRA[@]}"

    collect_jaeger "$PROM_START" "$END_TS" "$OUT_DIR/jaeger"

    validate_required_metrics "$OUT_DIR" nf_cpu.csv total_monitoring_cpu.csv || true
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
    require_health_check "post-combined-run${RUN}" \
        "$OUT_DIR/health_post.json" "$MIN_TUNNELS" || true

    echo "[run $RUN done] Data in: $OUT_DIR"
done

echo ""
echo "============================================================"
echo " Experiment 04 complete. Data in: $OUT_BASE"
echo "============================================================"

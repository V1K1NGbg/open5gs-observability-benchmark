#!/usr/bin/env bash
# A/02_prometheus_sweep.sh
#
# Experiment 02 — Prometheus Scrape Interval Sweep
#
# Condition:
#   Open5GS NF metrics endpoints : ENABLED
#   Prometheus server             : ENABLED — Active Subject Under Test
#   Beyla DaemonSet               : DISABLED
#   Measurement tool              : Prometheus self-metrics + cAdvisor via Prometheus API
#
# Variables:
#   Scrape intervals: 1s, 5s, 15s, 30s
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
OUT_BASE="$DATA_DIR/A/02-prometheus-sweep"
MIN_TUNNELS=$(( UE_COUNT * 8 / 10 ))

INTERVALS=(1s 5s 15s 30s)

# Shared extra-metric queries (Prometheus server only, not operator/alertmanager)
_PROM_EXTRA=(
    "prom_cpu:rate(process_cpu_seconds_total{job=\"kube-prom-kube-prometheus-prometheus\"}[2m]):prom_self_cpu.csv"
    "prom_mem:process_resident_memory_bytes{job=\"kube-prom-kube-prometheus-prometheus\"}:prom_self_mem.csv"
    "prom_samples:rate(prometheus_tsdb_head_samples_appended_total[2m]):prom_tsdb_sample_rate.csv"
    "prom_scrape_dur:prometheus_target_interval_length_seconds{job=~\".*\",quantile=\"0.99\"}:prom_scrape_p99.csv"
    "net_rx_monitoring:rate(container_network_receive_bytes_total{namespace=\"monitoring\"}[2m]):monitoring_net_rx.csv"
    "net_tx_monitoring:rate(container_network_transmit_bytes_total{namespace=\"monitoring\"}[2m]):monitoring_net_tx.csv"
    "nf_cpu:rate(container_cpu_usage_seconds_total{namespace=\"open5gs\",container!=\"\",container!~\"POD|beyla.*\"}[2m]):nf_cpu.csv"
    "nf_mem:container_memory_working_set_bytes{namespace=\"open5gs\",container!=\"\",container!~\"POD|beyla.*\"}:nf_mem.csv"
    "total_monitoring_cpu:rate(container_cpu_usage_seconds_total{namespace=\"monitoring\",container!=\"\"}[2m]):total_monitoring_cpu.csv"
    "total_monitoring_mem:container_memory_working_set_bytes{namespace=\"monitoring\",container!=\"\"}:total_monitoring_mem.csv"
)

echo "============================================================"
echo " Experiment 02 — Prometheus Scrape Interval Sweep"
echo " intervals=${INTERVALS[*]}  replications=${REPLICATIONS}"
echo " duration=${COLLECTION_DURATION}s  ues=${UE_COUNT}"
echo "============================================================"

check_cluster_ready

for INTERVAL in "${INTERVALS[@]}"; do
    echo ""
    echo "------------------------------------------------------------"
    echo " Scrape interval: $INTERVAL"
    echo "------------------------------------------------------------"

    for RUN in $(seq 1 "$REPLICATIONS"); do
        echo ""
        echo "  [run $RUN/$REPLICATIONS] interval=$INTERVAL"
        OUT_DIR="$OUT_BASE/${INTERVAL}/run_${RUN}"
        mkdir -p "$OUT_DIR"

        if should_skip_run "$OUT_DIR" "$INTERVAL" "$RUN"; then
            continue
        fi

        # ── Full cluster reset + UE scaling ────────────────────────────
        echo "  [reset] Full cluster restart for clean run..."
        setup_cluster_with_ues "$UE_COUNT"

        # ── Configure telemetry AFTER cluster is up ──────────────────
        disable_beyla
        set_prometheus_scrape_interval "$INTERVAL"
        enable_prometheus_server
        ensure_portforward_prometheus

        # ── Wait for cluster stability ───────────────────────────────
        wait_for_pods_stable open5gs 180
        INTERVAL_S="${INTERVAL%s}"
        WARMUP=$(( INTERVAL_S * 3 < 30 ? 30 : INTERVAL_S * 3 ))
        echo "  [warmup] ${WARMUP}s Prometheus warmup at ${INTERVAL} interval..."
        sleep "$WARMUP"

        # ── Pre-run health check (blocking) ──────────────────────────
        require_health_check "pre-prom-${INTERVAL}-run${RUN}" \
            "$OUT_DIR/health_pre.json" "$MIN_TUNNELS"

        # ── Write metadata ───────────────────────────────────────────
        log_experiment_start "02-prometheus-${INTERVAL}-run${RUN}" "$OUT_DIR"
        GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        python3 -c "
import json; d = json.load(open('$OUT_DIR/meta.json'))
d.update({'condition': '02-prometheus-sweep',
          'scrape_interval': '$INTERVAL',
          'run': $RUN,
          'replications': $REPLICATIONS,
          'ue_count': $UE_COUNT,
          'collection_duration_s': $COLLECTION_DURATION,
          'rate_warmup_s': $RATE_WARMUP_S,
          'git_sha': '$GIT_SHA',
          'prometheus_enabled': True,
          'beyla_enabled': False,
          'open5gs_metrics_enabled': True,
          'rtt_metric': 'data_plane_ping_ms'})
json.dump(d, open('$OUT_DIR/meta.json', 'w'), indent=2)
"
        START_TS=$(date +%s)

        # ── Collect UE RTT in background ─────────────────────────────
        bash "$LIB_DIR/collect_ue_rtt.sh" "$COLLECTION_DURATION" "$OUT_DIR/ue_rtt.csv" &
        RTT_PID=$!

        # ── Sleep for the collection window ──────────────────────────
        sleep_with_progress "$COLLECTION_DURATION" "collecting"

        # ── Wait for RTT, then set END_TS ────────────────────────────
        wait "$RTT_PID" || { mark_run_invalid "$OUT_DIR" "rtt_collector_failed"; exit 1; }
        END_TS=$(date +%s)
        PROM_START=$(prom_query_start "$START_TS")

        # ── Query Prometheus (trim rate warmup from query window) ────
        collect_prometheus "$PROM_START" "$END_TS" "${INTERVAL}" "$OUT_DIR/prometheus"
        collect_prometheus_extra "$PROM_START" "$END_TS" "${INTERVAL}" "$OUT_DIR/prometheus" \
            "${_PROM_EXTRA[@]}"

        validate_required_metrics "$OUT_DIR" nf_cpu.csv prom_self_cpu.csv || true
        validate_ue_rtt "$OUT_DIR" 0.5 && mark_run_valid "$OUT_DIR" || true

        # ── Finalise metadata ────────────────────────────────────────
        python3 -c "
import json
d = json.load(open('$OUT_DIR/meta.json'))
d.update({'started_unix': $START_TS, 'ended_unix': $END_TS,
          'prom_query_start_unix': $PROM_START,
          'actual_duration_s': $END_TS - $START_TS})
json.dump(d, open('$OUT_DIR/meta.json', 'w'), indent=2)
"
        log_experiment_end "$OUT_DIR"
        require_health_check "post-prom-${INTERVAL}-run${RUN}" \
            "$OUT_DIR/health_post.json" "$MIN_TUNNELS" || true

        echo "  [run $RUN done] Data in: $OUT_DIR"
    done
done

set_prometheus_scrape_interval "5s"
enable_beyla

echo ""
echo "============================================================"
echo " Experiment 02 complete. Data in: $OUT_BASE"
echo "============================================================"

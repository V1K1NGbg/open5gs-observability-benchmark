#!/usr/bin/env bash
# A/run_all.sh
#
# Group A orchestrator — Observability Overhead experiments.
#
# Runs the five A-series experiments in sequence:
#   01 — No-Telemetry True Baseline
#   02 — Prometheus Scrape Interval Sweep  (4 intervals × 6 runs = 24 runs)
#   03 — eBPF / Beyla Sampling Rate Sweep  (3 rates × 6 runs   = 18 runs)
#   04 — Combined Production Baseline      (3 iterations)
#   05 — Scalability & Capacity Sweep      (4 UE counts × 2 profiles)
#
# Estimated total runtime (5-minute collection windows):
#   01:  ~15 min
#   02:  ~2.5 h  (24 runs × ~6 min each including reset)
#   03:  ~2 h    (18 runs × ~6 min each)
#   04:  ~25 min
#   05:  ~1 h    (8 profiles × ~7 min each)
#   ──────────────────────────
#   Total: ~6.5 h
#
# Usage:
#   bash run_all.sh                   # run all
#   bash run_all.sh --from 03         # skip 01+02, start at 03
#   bash run_all.sh --only 01,04      # run only the listed experiments
#
# All env overrides from individual scripts are respected:
#   COLLECTION_DURATION, UE_COUNT, REPLICATIONS, ITERATIONS

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

FROM="01"
ONLY=""

while [[ $# -gt 0 ]]; do
    case "${1:-}" in
        --from) FROM="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        *) shift ;;
    esac
done

_should_run() {
    local num="$1"
    if [[ -n "$ONLY" ]]; then
        echo ",$ONLY," | grep -q ",${num}," && return 0 || return 1
    fi
    [[ "$num" < "$FROM" ]] && return 1
    return 0
}

run_experiment() {
    local num="$1" script="$2" label="$3"
    if ! _should_run "$num"; then
        echo "[skip] Experiment $num ($label)"
        return
    fi
    echo ""
    echo "████████████████████████████████████████████████████████████"
    echo " Experiment $num: $label"
    echo "████████████████████████████████████████████████████████████"
    bash "$SCRIPT_DIR/$script"
    echo ""
    echo "[exp $num done] Sleeping 60s cooldown before next experiment..."
    sleep 60
}

echo "============================================================"
echo " Group A — Observability Overhead Experiments"
echo " from=$FROM  only=${ONLY:-all}"
echo "============================================================"

run_experiment "01" "01_baseline.sh"          "No-Telemetry True Baseline"
run_experiment "02" "02_prometheus_sweep.sh"  "Prometheus Scrape Interval Sweep"
run_experiment "03" "03_beyla_sweep.sh"       "eBPF / Beyla Sampling Rate Sweep"
run_experiment "04" "04_combined.sh"          "Combined Production Baseline"
run_experiment "05" "05_scalability.sh"       "Scalability & Capacity Sweep"

echo ""
echo "============================================================"
echo " Group A complete. Data in: $DATA_DIR/A/"
echo "============================================================"

if [[ "${RUN_ANALYSIS:-0}" == "1" ]]; then
    echo ""
    echo "[analysis] RUN_ANALYSIS=1 — regenerating figures..."
    python3 "$SCRIPT_DIR/../../analysis/A_analysis.py"
fi

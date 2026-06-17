#!/usr/bin/env bash
# A/05_scalability.sh
#
# Experiment 05 — Monitoring-Scope Scalability: Prometheus vs Beyla
#
# Fixed load: 15 UEs (steady 5G data-plane traffic).
# Variable: number of NFs monitored, swept from 1 to the pool maximum.
#
# Two independent sweeps on the same live cluster:
#
#   PASS 1 — Prometheus
#     NF pool  : all 12 5G SA NFs (requires kind/enable-extra-nf-metrics.sh)
#     Mechanism: toggle ServiceMonitor selectors — no pod restarts
#     Metric   : Prometheus process CPU  (prom_self_cpu.csv)
#     Schedule : n=1..12, up to MAX_COMBOS_PER_N combos  →  ~56 combos × 4.5 min ≈ 4 h
#
#   PASS 2 — Beyla
#     NF pool  : all 12 5G SA NFs (instruments by executable name)
#     Mechanism: BEYLA_EXECUTABLE_NAME env-var → DaemonSet rollout per combo
#     Metric   : Beyla container CPU  (beyla_cpu.csv)
#     Schedule : n=1..12, up to MAX_COMBOS_PER_N combos  →  ~56 combos × 5.5 min ≈ 5 h
#
# Output layout:
#   data/experiments/A/05-scalability/prometheus/{n}nf/{combo}/
#   data/experiments/A/05-scalability/beyla/{n}nf/{combo}/
#
# Env overrides:
#   COLLECTION_DURATION   (default 240 s per combo)
#   SETTLE_TIME           (default 30 s — Prometheus target discovery)
#   BEYLA_ROLLOUT_WAIT    (default 90 s — DaemonSet rollout timeout)
#   MAX_COMBOS_PER_N      (default 5)
#   PROM_NFS              (space-separated NF pool for Prometheus pass)
#   BEYLA_NFS             (space-separated NF pool for Beyla pass)
#   SKIP_PROM_SWEEP       (default 0 — set 1 to skip Prometheus pass)
#   SKIP_BEYLA_SWEEP      (default 0 — set 1 to skip Beyla pass)
#   SKIP_CLUSTER_RESET    (default 0 — set 1 to reuse live cluster, no teardown)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/configure_telemetry.sh"

COLLECTION_DURATION="${COLLECTION_DURATION:-240}"
SETTLE_TIME="${SETTLE_TIME:-30}"
BEYLA_ROLLOUT_WAIT="${BEYLA_ROLLOUT_WAIT:-90}"
MAX_COMBOS_PER_N="${MAX_COMBOS_PER_N:-5}"
UE_COUNT=15
OUT_BASE="$DATA_DIR/A/05-scalability"

SKIP_PROM_SWEEP="${SKIP_PROM_SWEEP:-0}"
SKIP_BEYLA_SWEEP="${SKIP_BEYLA_SWEEP:-0}"
SKIP_CLUSTER_RESET="${SKIP_CLUSTER_RESET:-0}"

# All 12 5G SA NFs — Prometheus needs kind/enable-extra-nf-metrics.sh to have
# run so NRF/AUSF/BSF/UDM/UDR/SCP/NSSF/SEPP have ServiceMonitors.
# Beyla instruments any process by executable name, so it naturally covers all.
read -ra PROM_NFS  <<< "${PROM_NFS:-amf smf upf pcf nrf ausf bsf udm udr scp nssf sepp}"
read -ra BEYLA_NFS <<< "${BEYLA_NFS:-amf smf upf pcf nrf ausf bsf udm udr scp nssf sepp}"

PROM_N_MAX="${#PROM_NFS[@]}"
BEYLA_N_MAX="${#BEYLA_NFS[@]}"

# Collected in every window regardless of backend.
# prom_self_cpu → Prometheus process cost;  beyla_cpu → Beyla container cost.
_EXTRA=(
    "prom_cpu:rate(process_cpu_seconds_total{job=\"kube-prom-kube-prometheus-prometheus\"}[2m]):prom_self_cpu.csv"
    "beyla_cpu:sum(rate(container_cpu_usage_seconds_total{namespace=\"open5gs\",pod=~\"beyla.*\",container=\"beyla\"}[2m])):beyla_cpu.csv"
    "nf_cpu:sum(rate(container_cpu_usage_seconds_total{namespace=\"open5gs\",container!=\"\",container!~\"POD|beyla.*\"}[2m])):nf_cpu.csv"
    "total_monitoring_cpu:sum(rate(container_cpu_usage_seconds_total{namespace=\"monitoring\",container!=\"\"}[2m])):total_monitoring_cpu.csv"
)

MIN_TUNNELS=$(( UE_COUNT * 8 / 10 ))
[[ "$MIN_TUNNELS" -lt 5 ]] && MIN_TUNNELS=5

# generate_combos <n> <nf1> <nf2> ...
# Prints every combination of size n from the NF list, one per line,
# space-separated.  Capped at MAX_COMBOS_PER_N.
generate_combos() {
    local n="$1"; shift
    local nfs_json
    nfs_json=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" "$@")
    python3 -c "
from itertools import combinations
import json, sys
nfs = json.loads('${nfs_json}')
limit = int('${MAX_COMBOS_PER_N}')
for combo in list(combinations(nfs, int('${n}')))[:limit]:
    print(' '.join(combo))
"
}

_is_valid() {
    local dir="$1"
    [[ "${SKIP_VALID_RUNS:-1}" == "1" ]] && \
    [[ -f "$dir/meta.json" ]] && \
    python3 -c "
import json,sys
d=json.load(open('$dir/meta.json'))
sys.exit(0 if d.get('data_valid') is True else 1)
" 2>/dev/null
}

_count_missing() {
    local backend="$1"; shift
    local -a nfs=("$@")
    local n_max="${#nfs[@]}" missing=0
    for n in $(seq 1 "$n_max"); do
        while IFS= read -r combo; do
            local combo_name dir
            combo_name=$(echo "$combo" | tr ' ' '_')
            dir="$OUT_BASE/${backend}/${n}nf/${combo_name}"
            _is_valid "$dir" || missing=$(( missing + 1 ))
        done < <(generate_combos "$n" "${nfs[@]}")
    done
    echo "$missing"
}

# _run_combo <backend> <n> <combo>
# Configures monitoring scope, waits, collects, validates.
_run_combo() {
    local backend="$1" n="$2" combo="$3"
    local combo_name n_label out_dir
    combo_name=$(echo "$combo" | tr ' ' '_')
    n_label="${n}nf"
    out_dir="$OUT_BASE/${backend}/${n_label}/${combo_name}"
    mkdir -p "$out_dir"

    if _is_valid "$out_dir"; then
        echo "  [skip] ${backend}/${n_label}/${combo_name} — already valid"
        return 0
    fi

    echo ""
    echo "------------------------------------------------------------"
    echo " ${backend} / ${n_label} / ${combo_name}  |  NFs: ${combo}"
    echo "------------------------------------------------------------"

    if [[ "$backend" == "prometheus" ]]; then
        # shellcheck disable=SC2086
        enable_specific_nf_metrics $combo
        echo "[settle] ${SETTLE_TIME}s for Prometheus to discover new scrape targets..."
        sleep "$SETTLE_TIME"
    else
        # shellcheck disable=SC2086
        enable_specific_nf_beyla $combo
        echo "[settle] ${SETTLE_TIME}s post-rollout settle..."
        sleep "$SETTLE_TIME"
    fi

    log_experiment_start "05-scalability-${backend}-${n_label}-${combo_name}" "$out_dir"

    local nfs_json
    nfs_json=$(python3 -c "import json; print(json.dumps('${combo}'.split()))")

    python3 -c "
import json
d = json.load(open('$out_dir/meta.json'))
d.update({
    'condition':             '05-scalability',
    'backend':               '$backend',
    'n_monitored_nfs':       $n,
    'combo_name':            '$combo_name',
    'monitored_nfs':         $nfs_json,
    'ue_count':              $UE_COUNT,
    'collection_duration_s': $COLLECTION_DURATION,
    'settle_time_s':         $SETTLE_TIME,
    'rate_warmup_s':         $RATE_WARMUP_S,
    'git_sha':               '$GIT_SHA',
    'scrape_interval':       '5s',
})
json.dump(d, open('$out_dir/meta.json', 'w'), indent=2)
"
    local start_ts end_ts prom_start
    start_ts=$(date +%s)

    sleep_with_progress "$COLLECTION_DURATION" \
        "collecting (${backend} / ${n} NFs: ${combo_name})"

    end_ts=$(date +%s)
    prom_start=$(prom_query_start "$start_ts")

    collect_prometheus "$prom_start" "$end_ts" "5s" "$out_dir/prometheus"
    collect_prometheus_extra "$prom_start" "$end_ts" "5s" "$out_dir/prometheus" \
        "${_EXTRA[@]}"

    python3 -c "
import json
d = json.load(open('$out_dir/meta.json'))
d.update({
    'started_unix':          $start_ts,
    'ended_unix':            $end_ts,
    'prom_query_start_unix': $prom_start,
    'actual_duration_s':     $end_ts - $start_ts,
})
json.dump(d, open('$out_dir/meta.json', 'w'), indent=2)
"
    if [[ "$backend" == "prometheus" ]]; then
        validate_required_metrics "$out_dir" prom_self_cpu.csv nf_cpu.csv && \
            mark_run_valid "$out_dir" || true
    else
        validate_required_metrics "$out_dir" beyla_cpu.csv nf_cpu.csv && \
            mark_run_valid "$out_dir" || true
    fi

    log_experiment_end "$out_dir"
    echo "[done] ${backend}/${n_label}/${combo_name} → $out_dir"
}

# ── Header ─────────────────────────────────────────────────────────────────
echo "============================================================"
echo " Experiment 05 — Monitoring-Scope Scalability Sweep"
echo " PROMETHEUS  NFs: ${PROM_NFS[*]}  (n=1..${PROM_N_MAX})"
echo " BEYLA       NFs: ${BEYLA_NFS[*]}  (n=1..${BEYLA_N_MAX})"
echo " Fixed: ${UE_COUNT} UEs  |  max combos/n: ${MAX_COMBOS_PER_N}"
echo " Collection: ${COLLECTION_DURATION}s/combo  |  Settle: ${SETTLE_TIME}s"
echo " Beyla rollout wait: ${BEYLA_ROLLOUT_WAIT}s"
echo "============================================================"

missing_prom=0
missing_beyla=0
[[ "$SKIP_PROM_SWEEP"  == "0" ]] && missing_prom=$(_count_missing  "prometheus" "${PROM_NFS[@]}")
[[ "$SKIP_BEYLA_SWEEP" == "0" ]] && missing_beyla=$(_count_missing "beyla"      "${BEYLA_NFS[@]}")

total_missing=$(( missing_prom + missing_beyla ))
if [[ "$total_missing" -eq 0 ]]; then
    echo "[skip] All combinations already valid — nothing to do."
    exit 0
fi
echo "[info] ${missing_prom} Prometheus + ${missing_beyla} Beyla combo(s) need collection."

# ── Cluster reset (optional) ───────────────────────────────────────────────
if [[ "$SKIP_CLUSTER_RESET" == "1" ]]; then
    echo "[reset] SKIP_CLUSTER_RESET=1 — reusing live cluster"
else
    echo "[reset] Full cluster restart (UE_COUNT=${UE_COUNT})..."
    setup_cluster_with_ues "$UE_COUNT"
fi

restore_production_telemetry
set_prometheus_scrape_interval "5s"
ensure_portforward_prometheus

wait_for_pods_stable open5gs 180
echo "[warmup] 45s warmup for telemetry stack..."
sleep 45

require_health_check "pre-scale" "$OUT_BASE/health_pre.json" "$MIN_TUNNELS"

GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")

# ── PASS 1: Prometheus sweep ────────────────────────────────────────────────
if [[ "$SKIP_PROM_SWEEP" == "0" ]] && [[ "$missing_prom" -gt 0 ]]; then
    echo ""
    echo "============================================================"
    echo " PASS 1: Prometheus sweep  (NFs: ${PROM_NFS[*]}, n=1..${PROM_N_MAX})"
    echo " Beyla stays at full scope; only ServiceMonitors vary."
    echo "============================================================"

    restore_beyla_full_scope

    for n in $(seq 1 "$PROM_N_MAX"); do
        echo ""
        echo "── Prometheus  n=${n} NF(s) ───────────────────────────────────"
        while IFS= read -r combo; do
            _run_combo "prometheus" "$n" "$combo"
        done < <(generate_combos "$n" "${PROM_NFS[@]}")
    done

    enable_open5gs_metrics
    echo "[pass 1 done] All Prometheus ServiceMonitors restored."
fi

# ── PASS 2: Beyla sweep ─────────────────────────────────────────────────────
if [[ "$SKIP_BEYLA_SWEEP" == "0" ]] && [[ "$missing_beyla" -gt 0 ]]; then
    echo ""
    echo "============================================================"
    echo " PASS 2: Beyla sweep  (NFs: ${BEYLA_NFS[*]}, n=1..${BEYLA_N_MAX})"
    echo " Prometheus scrapes ALL NFs (full ServiceMonitors); only Beyla scope varies."
    echo "============================================================"

    enable_open5gs_metrics

    require_health_check "mid-scale" "$OUT_BASE/health_mid.json" "$MIN_TUNNELS" || true

    for n in $(seq 1 "$BEYLA_N_MAX"); do
        echo ""
        echo "── Beyla  n=${n} NF(s) ────────────────────────────────────────"
        while IFS= read -r combo; do
            _run_combo "beyla" "$n" "$combo"
        done < <(generate_combos "$n" "${BEYLA_NFS[@]}")
    done

    restore_beyla_full_scope
    echo "[pass 2 done] Beyla scope restored."
fi

# ── Finalize ─────────────────────────────────────────────────────────────────
restore_production_telemetry

require_health_check "post-scale" "$OUT_BASE/health_post.json" "$MIN_TUNNELS" || true

echo ""
echo "============================================================"
echo " Experiment 05 complete."
echo " Prometheus data: $OUT_BASE/prometheus/"
echo " Beyla data:      $OUT_BASE/beyla/"
echo "============================================================"

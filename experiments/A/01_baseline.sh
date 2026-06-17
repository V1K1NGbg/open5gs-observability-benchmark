#!/usr/bin/env bash
# A/01_baseline.sh
#
# Experiment 01 — No-Telemetry True Baseline
#
# Condition:
#   Open5GS NF metrics endpoints : DISABLED (ServiceMonitors suspended)
#   Prometheus server             : DISABLED (paused)
#   Beyla DaemonSet               : DISABLED (no scheduled pods)
#   Measurement tool              : Host cgroups + /proc via privileged collector pod
#
# Objective:
#   Establish the raw 5G Core resource footprint (CPU millicores, memory bytes)
#   and data-plane ping RTT with zero telemetry overhead.
#   All downstream experiments subtract this baseline to isolate monitoring cost.
#
# Outputs (data/experiments/A/01-baseline/):
#   cgroups/          — per-node cgroup_samples.csv, node_cpu_idle.csv, node_memory.csv
#   ue_rtt.csv        — per-second RTT/loss from uesimtun0 → UPF gateway
#   meta.json         — start/end timestamps, UE count, git SHA
#
# Env overrides:
#   COLLECTION_DURATION  (default 300s / 5 min)
#   CGROUP_INTERVAL      (default 5s)
#   UE_COUNT             (default 50)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/configure_telemetry.sh"

COLLECTION_DURATION="${COLLECTION_DURATION:-300}"
CGROUP_INTERVAL="${CGROUP_INTERVAL:-5}"
UE_COUNT="${UE_COUNT:-50}"
OUT_DIR="$DATA_DIR/A/01-baseline"
mkdir -p "$OUT_DIR"

echo "============================================================"
echo " Experiment 01 — No-Telemetry True Baseline"
echo " duration=${COLLECTION_DURATION}s  ues=${UE_COUNT}"
echo "============================================================"

check_cluster_ready

# ── Step 1: Full cluster reset + UE scaling ───────────────────────────────
echo "[01] Resetting cluster state..."
setup_cluster_with_ues "$UE_COUNT"

# ── Step 2: Disable all telemetry AFTER cluster is up ───────────────────────
echo "[01] Disabling telemetry stack..."
disable_beyla
disable_prometheus_server
disable_open5gs_metrics

# Do NOT start port-forwards — Prometheus is disabled.

# ── Step 3: Wait for 5G Core to stabilise without any telemetry ───────────
echo "[01] Waiting for NF pods to stabilise (90s)..."
wait_for_pods_stable open5gs 180
sleep 30

# ── Step 4: Health sanity check (blocking) ──────────────────────────────────
MIN_TUNNELS=$(( UE_COUNT * 8 / 10 ))
require_health_check "pre-baseline" "$OUT_DIR/health_pre.json" "$MIN_TUNNELS"

# ── Step 5: Log start metadata ────────────────────────────────────────────
log_experiment_start "01-no-telemetry-baseline" "$OUT_DIR"
GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
python3 -c "
import json; d = json.load(open('$OUT_DIR/meta.json'))
d.update({'condition': '01-no-telemetry-baseline',
          'ue_count': $UE_COUNT,
          'collection_duration_s': $COLLECTION_DURATION,
          'cgroup_interval_s': $CGROUP_INTERVAL,
          'rate_warmup_s': $RATE_WARMUP_S,
          'git_sha': '$GIT_SHA',
          'prometheus_enabled': False,
          'beyla_enabled': False,
          'open5gs_metrics_enabled': False,
          'rtt_metric': 'data_plane_ping_ms'})
json.dump(d, open('$OUT_DIR/meta.json', 'w'), indent=2)
"

START_TS=$(date +%s)

# ── Step 6: Collect UE RTT in background ──────────────────────────────────
RTT_OUT="$OUT_DIR/ue_rtt.csv"
bash "$LIB_DIR/collect_ue_rtt.sh" "$COLLECTION_DURATION" "$RTT_OUT" &
RTT_PID=$!

# ── Step 7: Collect cgroup / proc metrics ─────────────────────────────────
mkdir -p "$OUT_DIR/cgroups"
bash "$LIB_DIR/collect_cgroups.sh" "$COLLECTION_DURATION" "$CGROUP_INTERVAL" "$OUT_DIR/cgroups" &
CGROUP_PID=$!

# ── Step 8: Wait for both collectors to complete ──────────────────────────
echo "[01] Collection running for ${COLLECTION_DURATION}s..."
wait "$RTT_PID" || { mark_run_invalid "$OUT_DIR" "rtt_collector_failed"; exit 1; }
wait "$CGROUP_PID" || { mark_run_invalid "$OUT_DIR" "cgroup_collector_failed"; exit 1; }

END_TS=$(date +%s)

# ── Step 9: Parse UERANSIM logs for registration events ───────────────────
echo "[01] Extracting UERANSIM registration events from logs..."
UEREG_OUT="$OUT_DIR/ue_registration_latency.csv"
echo "log_time,ue_imsi,event" > "$UEREG_OUT"
kubectl logs -n open5gs deployment/ueransim-gnb-ues \
    --since="${COLLECTION_DURATION}s" 2>/dev/null \
    | grep -E "(Sending Initial Registration|Registration complete|Registration failed|Registration accepted|Registration reject|MM-REGISTERED)" \
    | awk '{
        ts = $1 " " $2
        gsub(/[\[\]]/, "", ts)
        imsi_field = $3
        gsub(/^\[/, "", imsi_field)
        gsub(/\|.*/, "", imsi_field)
        event = ""
        for (i=5; i<=NF; i++) {
            if ($i ~ /Registration|MM-REGISTERED/) {
                event = $i
                if (i+1 <= NF) event = event " " $(i+1)
                break
            }
        }
        print ts "," imsi_field "," event
    }' >> "$UEREG_OUT" || true

# ── Step 10: Finalise metadata ────────────────────────────────────────────
python3 -c "
import json
d = json.load(open('$OUT_DIR/meta.json'))
d['started_unix'] = $START_TS
d['ended_unix']   = $END_TS
d['prom_query_start_unix'] = $START_TS + $RATE_WARMUP_S
d['actual_duration_s'] = $END_TS - $START_TS
json.dump(d, open('$OUT_DIR/meta.json', 'w'), indent=2)
"

# Validate cgroup data and RTT
if ! ls "$OUT_DIR/cgroups"/*_node_cpu_idle.csv &>/dev/null; then
    mark_run_invalid "$OUT_DIR" "empty_cgroups_dir"
else
    validate_ue_rtt "$OUT_DIR" 0.5 && mark_run_valid "$OUT_DIR" || true
fi

log_experiment_end "$OUT_DIR"

# ── Step 11: Post-check, then restore telemetry ───────────────────────────
require_health_check "post-baseline" "$OUT_DIR/health_post.json" "$MIN_TUNNELS" || true

echo "[01] Restoring telemetry stack for subsequent experiments..."
restore_production_telemetry

echo ""
echo "============================================================"
echo " Experiment 01 complete. Data in: $OUT_DIR"
echo "============================================================"

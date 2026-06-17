#!/usr/bin/env bash
# experiments/lib/run_fault.sh
#
# Generic fault lifecycle runner.
# Applies a Chaos Mesh manifest, collects pre/during/post telemetry from
# Prometheus + Jaeger + Loki + K8s events + NRF API, then removes the
# fault and lets the system recover.
#
# Per-fault customisations (in-container memory alloc, NF restarts, RTT
# ping for network faults) live in lib/hooks/<name>.sh and define any of
# the functions pre_inject / during_fault / post_delete. No-op defaults
# are provided so unhooked faults still work.
#
# Usage:
#   bash run_fault.sh \
#     --name    <fault-slug>          e.g. "01-cpu-stress-amf"
#     --manifest <path/to/chaos.yaml> \
#     --out     <output-dir>          \
#     --pre-duration  <seconds>       (default 120)
#     --fault-duration <seconds>      (default 300)
#     --post-duration <seconds>       (default 120)
#     --step    <prom-step>           (default "5s")

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/traffic.sh"

# Defaults (env-overridable; CLI flags below take precedence over env)
PRE_DURATION="${PRE_DURATION:-600}"
FAULT_DURATION="${FAULT_DURATION:-300}"
POST_DURATION="${POST_DURATION:-300}"
STEP="${STEP:-5s}"
NAME=""
MANIFEST=""
OUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)           NAME="$2";           shift 2 ;;
        --manifest)       MANIFEST="$2";       shift 2 ;;
        --out)            OUT_DIR="$2";        shift 2 ;;
        --pre-duration)   PRE_DURATION="$2";   shift 2 ;;
        --fault-duration) FAULT_DURATION="$2"; shift 2 ;;
        --post-duration)  POST_DURATION="$2";  shift 2 ;;
        --step)           STEP="$2";           shift 2 ;;
        *) echo "[run_fault] Unknown arg: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$NAME" ]]     && { echo "[run_fault] --name required" >&2; exit 1; }
[[ -z "$MANIFEST" ]] && { echo "[run_fault] --manifest required" >&2; exit 1; }
[[ -z "$OUT_DIR" ]]  && { echo "[run_fault] --out required" >&2; exit 1; }

export OUT_DIR NAME FAULT_DURATION   # hooks read these

mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# Hooks — define no-op defaults, then override from lib/hooks/<name>.sh
# ---------------------------------------------------------------------------
pre_inject()  { :; }
during_fault(){ :; }
post_delete() { :; }

HOOK_FILE="$SCRIPT_DIR/hooks/${NAME}.sh"
if [[ -f "$HOOK_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$HOOK_FILE"
    echo "[run_fault] loaded hooks: $HOOK_FILE"
fi

# ---------------------------------------------------------------------------
# Port-forwards + traffic
# ---------------------------------------------------------------------------
ensure_portforward_prometheus
ensure_portforward_jaeger
ensure_portforward_loki

# Cleanup trap (common.sh already installed one for port-forwards; we add
# stop_traffic in front of it via a new combined trap).
_run_fault_cleanup() {
    stop_traffic || true
    _cleanup     || true   # from common.sh — kills port-forwards
}
trap _run_fault_cleanup EXIT

start_traffic

# ---------------------------------------------------------------------------
# Data-plane cleanliness gate (orphaned-bearer guard)
# ---------------------------------------------------------------------------
# cluster-start.sh gates the control plane (pods Ready, NFs registered,
# pfcp_sessions_active>=10). It cannot see this failure: it runs before traffic
# exists, and the symptom only appears once the ping loop hits a UE whose PDU
# session was orphaned at bring-up (UPF floods 'Send Error Indication',
# contaminating the PRE baseline — seen in 7/22 prior runs).
#
# A real orphaned bearer = ONE stuck session pinged at 5/s -> a sustained,
# single-TEID flood (~100 SEI / 20s, all one TEID). Harmless churn (the 3-UE
# re-registration loop, or a repair re-attach) = a brief burst spread across
# several TEIDs. So "dirty" requires BOTH: total >= DP_FLOOD_MIN *and* one TEID
# >= DP_FLOOD_FRAC of them. We do NOT repair pre-emptively (that itself causes
# churn); only repair if a flood is seen, and let it settle before re-checking.
DP_FLOOD_MIN=40       # sustained: >=2 SEI/s over the 20s window
DP_FLOOD_FRAC=0.70    # single stuck session dominates
UPF_POD=$(kubectl get pod -n open5gs -l app.kubernetes.io/name=upf \
              -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

# prints "FLOOD <total> <topteid> <topcount>" or "OK <total>"; exit 0 always
_dp_check() {
    local lf
    lf=$(mktemp)
    kubectl logs -n open5gs "$UPF_POD" --since=20s > "$lf" 2>/dev/null
    python3 - "$DP_FLOOD_MIN" "$DP_FLOOD_FRAC" "$lf" <<'PYEOF'
import sys, re, collections
mn, frac, path = int(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
teid = collections.Counter()
for ln in open(path, errors="replace"):
    if "Send Error Indication" in ln:
        m = re.search(r"TEID:0x[0-9a-fA-F]+", ln)
        teid[m.group(0) if m else "?"] += 1
tot = sum(teid.values())
top, topc = (teid.most_common(1)[0] if teid else ("-", 0))
print(f"FLOOD {tot} {top} {topc}" if (tot >= mn and topc >= frac * tot)
      else f"OK {tot}")
PYEOF
    rm -f "$lf"
}

DP_GATE_OK=0
for attempt in 1 2 3; do
    sleep 20
    res=$(_dp_check)
    if [[ "$res" == OK* ]]; then
        echo "[gate] data plane clean ($res) — proceeding"
        DP_GATE_OK=1; break
    fi
    echo "[gate] data plane dirty: $res (attempt $attempt/3) — repairing"
    repair_orphaned_bearers || true
    sleep 25   # let the re-attach churn drain before re-sampling
done
if [[ "$DP_GATE_OK" -ne 1 ]]; then
    echo "FATAL: single-TEID SEI flood persists after 3 repair attempts;" \
         "PRE baseline would be contaminated. Resume with --from N." >&2
    exit 1
fi
echo "[gate] data plane clean — proceeding to PRE window"

echo ""
echo "--- Fault: $NAME ---"
log_experiment_start "$NAME" "$OUT_DIR"

# ---------------------------------------------------------------------------
# Helper: collect all five signals into <out>/{prometheus,jaeger,loki}/<phase>
# plus <out>/events/<phase>/k8s_events.json and <out>/nrf/<phase>/nrf_registrations.json
# ---------------------------------------------------------------------------
collect_phase() {
    local phase="$1" start="$2" end="$3"
    collect_prometheus "$start" "$end" "$STEP" "$OUT_DIR/prometheus/$phase"
    collect_jaeger     "$start" "$end"         "$OUT_DIR/jaeger/$phase"
    collect_loki       "$start" "$end"         "$OUT_DIR/loki/$phase"
    collect_events     "$start" "$end"         "$OUT_DIR/events/$phase"
    collect_nrf                                "$OUT_DIR/nrf/$phase"
}

# collect_nrf_early: take NRF snapshot immediately (used right after fault injection)
collect_nrf_early() {
    local phase="$1"
    collect_nrf "$OUT_DIR/nrf/${phase}-early"
}

# ---------------------------------------------------------------------------
# PRE window
# ---------------------------------------------------------------------------
echo "[fault] PRE window (${PRE_DURATION}s)..."
PRE_START=$(now_ts)
mkdir -p "$OUT_DIR/rtt/pre"
bash "$LIB_DIR/collect_ue_rtt.sh" "$PRE_DURATION" "$OUT_DIR/rtt/pre/ue_rtt.csv" &
PRE_RTT_PID=$!
sleep_with_progress "$PRE_DURATION" "pre-fault baseline"
PRE_END=$(now_ts)
wait "$PRE_RTT_PID" 2>/dev/null || true
collect_phase pre "$PRE_START" "$PRE_END"

# Fail-safe: even past the gate, refuse a baseline saturated by a single
# orphaned bearer (one TEID's 'Send Error Indication' > 30% of pre error lines).
PRE_ERR="$OUT_DIR/loki/pre/errors.csv"
if [[ -f "$PRE_ERR" ]] && ! python3 - "$PRE_ERR" <<'PYEOF'
import csv, re, sys, collections
rows = list(csv.reader(open(sys.argv[1], newline='')))
body = rows[1:] if rows else []
if not body:
    sys.exit(0)
teid = collections.Counter()
for r in body:
    line = r[-1] if r else ""
    if "Send Error Indication" in line:
        m = re.search(r"TEID:0x[0-9a-fA-F]+", line)
        teid[m.group(0) if m else "?"] += 1
top = max(teid.values()) if teid else 0
sys.exit(1 if top > 0.30 * len(body) else 0)
PYEOF
then
    echo "FATAL: PRE baseline contaminated by an orphaned-bearer SEI flood" \
         "(single TEID > 30% of $PRE_ERR). Discard & resume with --from N." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Inject fault
# ---------------------------------------------------------------------------
echo "[fault] pre_inject hook..."
pre_inject

echo "[fault] Injecting fault: $MANIFEST"
kubectl apply -f "$MANIFEST"
FAULT_START=$(now_ts)

echo "[fault] during_fault hook (background)..."
during_fault

# Snapshot NRF immediately after injection — NRF pod recovers within the fault
# window so an end-of-window snapshot always shows normal counts (Bug 6).
collect_nrf_early "during"

# Start UE-side RTT collection in background for the fault window
UE_RTT_FILE="$OUT_DIR/rtt/during/ue_rtt.csv"
mkdir -p "$OUT_DIR/rtt/during"
bash "$LIB_DIR/collect_ue_rtt.sh" "$FAULT_DURATION" "$UE_RTT_FILE" &
UE_RTT_PID=$!

sleep_with_progress "$FAULT_DURATION" "fault active"
FAULT_END=$(now_ts)
wait "$UE_RTT_PID" 2>/dev/null || true
collect_phase during "$FAULT_START" "$FAULT_END"

# ---------------------------------------------------------------------------
# Remove fault — with finalizer-patching fallback if delete hangs.
# ---------------------------------------------------------------------------
echo "[fault] Removing fault..."
kubectl delete -f "$MANIFEST" --ignore-not-found=true &
DELETE_PID=$!
sleep 15
if kill -0 "$DELETE_PID" 2>/dev/null; then
    echo "[fault] WARN: delete still running after 15s — patching finalizers..."
    for kind in networkchaos stresschaos podchaos; do
        kubectl get "$kind" -n open5gs --no-headers 2>/dev/null \
            | awk '{print $1}' | while read -r name; do
                kubectl patch "$kind/$name" -n open5gs --type='json' \
                    -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
            done
    done
    wait "$DELETE_PID" 2>/dev/null || true
fi
REMOVE_TS=$(now_ts)

echo "[fault] post_delete hook..."
post_delete

# ---------------------------------------------------------------------------
# POST window
# ---------------------------------------------------------------------------
echo "[fault] POST window (${POST_DURATION}s)..."
mkdir -p "$OUT_DIR/rtt/post"
bash "$LIB_DIR/collect_ue_rtt.sh" "$POST_DURATION" "$OUT_DIR/rtt/post/ue_rtt.csv" &
POST_RTT_PID=$!
sleep_with_progress "$POST_DURATION" "post-fault recovery"
POST_END=$(now_ts)
wait "$POST_RTT_PID" 2>/dev/null || true
collect_phase post "$REMOVE_TS" "$POST_END"

# ---------------------------------------------------------------------------
# Write timeline
# ---------------------------------------------------------------------------
python3 -c "
import json
timeline = {
    'name':  '$NAME',
    'pre':   {'start': $PRE_START,   'end': $PRE_END},
    'fault': {'start': $FAULT_START, 'end': $FAULT_END},
    'post':  {'start': $REMOVE_TS,   'end': $POST_END},
}
with open('$OUT_DIR/timeline.json', 'w') as f:
    json.dump(timeline, f, indent=2)
"

log_experiment_end "$OUT_DIR"
echo "[fault] $NAME complete -> $OUT_DIR"

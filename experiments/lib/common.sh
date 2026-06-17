#!/usr/bin/env bash
# experiments/lib/common.sh
#
# Shared helpers for all experiment scripts.
# Source this file at the top of each experiment script:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
DATA_DIR="$REPO_ROOT/data/experiments"
CHAOS_DIR="$REPO_ROOT/kind/chaos"

# Port-forward PIDs (tracked for cleanup)
_PF_PIDS=()

# Prometheus, Jaeger, and Loki URLs (set by ensure_portforward_*)
PROM_URL="${PROM_URL:-http://127.0.0.1:9090}"
JAEGER_URL="${JAEGER_URL:-http://127.0.0.1:16686}"
LOKI_URL="${LOKI_URL:-http://127.0.0.1:3100}"

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------
_cleanup() {
    [[ ${#_PF_PIDS[@]} -eq 0 ]] && return
    for pid in "${_PF_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap _cleanup EXIT

# ---------------------------------------------------------------------------
# Experiment Reset
# ---------------------------------------------------------------------------
reset_experiment_state() {
    local strategy="${1:-unknown}"
    local ue_count="${2:-50}" 
    echo "[reset] Executing Sequential Cold Start: $strategy"

    kubectl exec -n monitoring svc/loki -- rm -rf /data/loki/chunks /data/loki/index /data/loki/boltdb-shipper-active /data/loki/compactor 2>/dev/null || true
    kubectl delete configmap -n monitoring loki-promtail-positions 2>/dev/null || true

    kubectl rollout restart -n monitoring statefulset/loki
    
    echo "  [reset] Waiting for Loki Rollout (180s)..."
    kubectl rollout status -n monitoring statefulset/loki --timeout=180s >/dev/null

    echo -n "  [reset] Waiting for Loki Pod readiness..."
    if kubectl wait --for=condition=ready pod/loki-0 -n monitoring --timeout=90s >/dev/null 2>&1; then
        echo " ready."
    else
        # Fallback: if name wait fails, try the label again with a broader scope
        echo -n " (using fallback selector)..."
        kubectl wait --for=condition=ready pod -n monitoring -l "app.kubernetes.io/instance=loki" --timeout=60s >/dev/null 2>&1 || \
        kubectl wait --for=condition=ready pod -n monitoring -l "app=loki" --timeout=60s >/dev/null 2>&1
        echo " ready."
    fi

    kubectl rollout restart daemonset -n monitoring loki-promtail

    echo "  [reset] Tier 1: Forced Restart of MongoDB and NRF..."
    local mongo_label="app.kubernetes.io/name=mongodb"
    kubectl delete pod -n open5gs -l "$mongo_label" --force --grace-period=0 2>/dev/null || true
    kubectl rollout restart deployment -n open5gs open5gs-nrf
    
    echo -n "  [reset] Waiting for MongoDB readiness..."
    kubectl wait --for=condition=ready pod -n open5gs -l "$mongo_label" --timeout=120s >/dev/null 2>&1
    echo " ready."

    echo "  [reset] Provisioning $ue_count subscribers..."
    kubectl scale deployment open5gs-populate -n open5gs --replicas=0 2>/dev/null || true
    kubectl delete pod -n open5gs -l app=open5gs-populate --force --grace-period=0 2>/dev/null || true
    
    bash "$LIB_DIR/provision_ues.sh" "$ue_count"

    echo "  [reset] Tier 2: Restarting remaining Network Functions..."
    kubectl get deployments -n open5gs -o name | grep -vE 'mongodb|nrf|populate' | xargs -r kubectl rollout restart -n open5gs

    echo -n "  [reset] Waiting for final stability..."
    wait_for_pods_stable open5gs 300
    
    sleep 20
    echo " done."
}
# ---------------------------------------------------------------------------
# Port-forward helpers
# ---------------------------------------------------------------------------

# start_portforward <namespace> <resource> <local_port> <remote_port>
start_portforward() {
    local ns="$1" resource="$2" local_port="$3" remote_port="$4"
    # Kill any stale process holding the port
    local stale
    stale=$(lsof -ti tcp:"$local_port" 2>/dev/null || true)
    [[ -n "$stale" ]] && kill "$stale" 2>/dev/null && sleep 1 || true
    kubectl port-forward -n "$ns" "$resource" "${local_port}:${remote_port}" \
        --address=127.0.0.1 >/dev/null 2>&1 &
    local pid=$!
    _PF_PIDS+=("$pid")
    # Wait until the port is actually open (max 60s)
    local i=0
    while ! (echo > /dev/tcp/127.0.0.1/"$local_port") 2>/dev/null; do
        sleep 1
        i=$((i+1))
        if [[ $i -ge 120 ]]; then
            echo "[ERROR] Port-forward to $resource:$remote_port never became ready" >&2
            return 1
        fi
    done
    echo "[pf] $resource → localhost:$local_port (pid $pid)"
}

# ensure_portforward_prometheus — idempotent, sets PROM_URL
ensure_portforward_prometheus() {
    PROM_URL="${PROM_URL:-http://127.0.0.1:9090}"
    if ! (echo > /dev/tcp/127.0.0.1/9090) 2>/dev/null; then
        start_portforward monitoring \
            svc/kube-prom-kube-prometheus-prometheus 9090 9090
    else
        echo "[pf] Prometheus already reachable at localhost:9090"
    fi
}

# ensure_portforward_jaeger — idempotent, sets JAEGER_URL
ensure_portforward_jaeger() {
    JAEGER_URL="${JAEGER_URL:-http://127.0.0.1:16686}"
    if ! (echo > /dev/tcp/127.0.0.1/16686) 2>/dev/null; then
        start_portforward monitoring svc/jaeger 16686 16686
    else
        echo "[pf] Jaeger already reachable at localhost:16686"
    fi
}

# ensure_portforward_loki — idempotent, sets LOKI_URL
ensure_portforward_loki() {
    LOKI_URL="${LOKI_URL:-http://127.0.0.1:3100}"
    if ! (echo > /dev/tcp/127.0.0.1/3100) 2>/dev/null; then
        start_portforward monitoring svc/loki 3100 3100
    else
        echo "[pf] Loki already reachable at localhost:3100"
    fi
}

# stop_portforward <local_port>
stop_portforward() {
    local port="$1"
    local pid
    pid=$(lsof -ti tcp:"$port" 2>/dev/null || true)
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Timing helpers
# ---------------------------------------------------------------------------

now_ts() { date +%s; }

# sleep_with_progress <seconds> <label>
sleep_with_progress() {
    local secs="$1" label="${2:-waiting}"
    echo -n "  [$label] ${secs}s "
    local i=0
    while [[ $i -lt $secs ]]; do
        sleep 10
        i=$((i+10))
        echo -n "."
    done
    echo " done"
}

# ---------------------------------------------------------------------------
# Cluster readiness
# ---------------------------------------------------------------------------

check_cluster_ready() {
    echo "[check] Verifying cluster context..."
    local ctx
    ctx=$(kubectl config current-context 2>/dev/null || true)
    kubectl cluster-info --context "$ctx" >/dev/null 2>&1 || {
        echo "[ERROR] Cluster $ctx not reachable" >&2
        exit 1
    }
    echo "[check] Cluster ready (context: $ctx)"
}

# ---------------------------------------------------------------------------
# Pod stability
# ---------------------------------------------------------------------------

# wait_for_pods_stable <namespace> <timeout_seconds>
wait_for_pods_stable() {
    local ns="$1" timeout="${2:-120}"
    echo -n "  [wait] Waiting for all pods in $ns to be Running "
    local i=0
    while true; do
        local not_ready
        not_ready=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
            | { grep -v -E "Running|Completed|Succeeded" || true; } \
            | { grep -v "open5gs-populate" || true; } | wc -l)
        if [[ "$not_ready" -eq 0 ]]; then
            echo " stable"
            return 0
        fi
        sleep 5
        i=$((i+5))
        echo -n "."
        if [[ $i -ge $timeout ]]; then
            echo " [WARN] pods not stable after ${timeout}s"
            return 0
        fi
    done
}

# ---------------------------------------------------------------------------
# UERANSIM UE scaling
# ---------------------------------------------------------------------------

# scale_ues <count>
#
# Scales UERANSIM to <count> total UEs using batched registration to avoid a
# known segfault in the nr-gnb process (gradiant/ueransim-gnb v0.2.6) when
# more than ~50 UEs register simultaneously.
#
# Strategy:
#   - First batch (UEs 1..BATCH_SIZE) runs inside ueransim-gnb-ues (gnb chart,
#     ues.enabled=true). BATCH_SIZE=25 is chosen safely below the crash threshold.
#   - Remaining UEs are deployed as separate ueransim-ues-batchN Helm releases,
#     each with BATCH_SIZE UEs and offset initialMSISDN, with a 30s gap between
#     batches to let the gNB process each wave before the next arrives.
#   - Any stale batch releases from a previous scale_ues call are removed first.
#
# _restart_core_for_ue_recovery
# Clears stale AMF/SMF/UDM state after failed PDU sessions or NGAP ID mismatches.
_restart_core_for_ue_recovery() {
    echo "  [wait] Restarting core NFs (SMF+UPF+AMF+UDM+UDR+PCF)..."
    kubectl rollout restart deployment/open5gs-smf deployment/open5gs-upf \
                                 deployment/open5gs-amf deployment/open5gs-udm \
                                 deployment/open5gs-udr deployment/open5gs-pcf -n open5gs 2>/dev/null || true
    kubectl rollout status deployment/open5gs-smf -n open5gs --timeout=120s 2>/dev/null || true
    kubectl rollout status deployment/open5gs-upf -n open5gs --timeout=120s 2>/dev/null || true
    kubectl rollout status deployment/open5gs-amf -n open5gs --timeout=120s 2>/dev/null || true
    kubectl rollout status deployment/open5gs-udm -n open5gs --timeout=120s 2>/dev/null || true
    kubectl rollout status deployment/open5gs-udr -n open5gs --timeout=120s 2>/dev/null || true
    kubectl rollout status deployment/open5gs-pcf -n open5gs --timeout=120s 2>/dev/null || true
    echo "  [wait] Waiting 30s for stale peer registrations to clear..."
    sleep 30
}

# _restart_all_ue_deployments
# Restarts gNB + every UE deployment (gnb-ues + batch releases).
_restart_all_ue_deployments() {
    kubectl rollout restart deployment/ueransim-gnb -n open5gs 2>/dev/null || true
    kubectl rollout status  deployment/ueransim-gnb -n open5gs --timeout=120s 2>/dev/null || true
    echo "  [wait] Waiting 20s for gNB cell broadcast to stabilize..."
    sleep 20
    kubectl rollout restart deployment/ueransim-gnb-ues -n open5gs 2>/dev/null || true
    kubectl rollout status  deployment/ueransim-gnb-ues -n open5gs --timeout=120s 2>/dev/null || true
    local batch
    for batch in $(helm list -n open5gs -q 2>/dev/null | grep "^ueransim-ues-batch" || true); do
        kubectl rollout restart "deployment/${batch}" -n open5gs 2>/dev/null || true
        kubectl rollout status  "deployment/${batch}" -n open5gs --timeout=120s 2>/dev/null || true
    done
}

scale_ues() {
    local count="$1"
    local BATCH_SIZE=25
    local BATCH_DELAY=30   # seconds between batches
    echo "[ues] Scaling UERANSIM UEs to $count (batch size $BATCH_SIZE)..."

    # cluster-start.sh installs standalone ueransim-ues (MSISDN 1..N) which overlaps
    # gnb-ues IMSIs and corrupts AMF/SMF state when scale_ues adds batch releases.
    if helm list -n open5gs -q 2>/dev/null | grep -qx "ueransim-ues"; then
        echo "[ues] Removing conflicting standalone ueransim-ues release"
        helm uninstall ueransim-ues --namespace open5gs 2>/dev/null || true
    fi

    # Remove any leftover batch releases from a prior run
    local existing_batches
    existing_batches=$(helm list -n open5gs -q 2>/dev/null | grep "^ueransim-ues-batch" || true)
    if [[ -n "$existing_batches" ]]; then
        echo "[ues] Removing stale batch releases: $existing_batches"
        echo "$existing_batches" | xargs -r helm uninstall --namespace open5gs 2>/dev/null || true
    fi

    # First batch: set ues.count inside the gnb chart (always <= BATCH_SIZE)
    local first_batch=$(( count < BATCH_SIZE ? count : BATCH_SIZE ))
    helm upgrade ueransim-gnb oci://registry-1.docker.io/gradiant/ueransim-gnb \
        --version 0.2.6 \
        --namespace open5gs \
        --reuse-values \
        --set ues.count="$first_batch" \
        --wait --timeout=3m 2>/dev/null || \
    helm upgrade ueransim-gnb oci://registry-1.docker.io/gradiant/ueransim-gnb \
        --version 0.2.6 \
        --namespace open5gs \
        --values https://gradiant.github.io/5g-charts/docs/open5gs-ueransim-gnb/gnb-ues-values.yaml \
        --set ues.count="$first_batch" \
        --wait --timeout=3m
    # The helm upgrade may have restarted the gNB pod. Wait for it to come up
    # and stabilize its cell broadcast before restarting UEs — otherwise UEs
    # get "no cells in coverage" and never register.
    kubectl rollout status deployment/ueransim-gnb -n open5gs --timeout=120s 2>/dev/null || true
    echo "[ues] Waiting 20s for gNB cell broadcast to stabilize after helm upgrade..."
    sleep 20
    kubectl rollout restart deployment/ueransim-gnb-ues -n open5gs 2>/dev/null || true
    kubectl rollout status  deployment/ueransim-gnb-ues -n open5gs --timeout=120s 2>/dev/null || true
    echo "[ues] Batch 0: $first_batch UEs (MSISDN 1..${first_batch})"

    # Additional batches for counts > BATCH_SIZE
    batch_num=1
    if [[ "$count" -gt "$BATCH_SIZE" ]]; then
        local deployed="$first_batch"
        while [[ "$deployed" -lt "$count" ]]; do
            local this_batch=$(( count - deployed < BATCH_SIZE ? count - deployed : BATCH_SIZE ))
            local msisdn_start=$(( deployed + 1 ))
            local msisdn_str
            printf -v msisdn_str "%010d" "$msisdn_start"

            echo "[ues] Waiting ${BATCH_DELAY}s before batch ${batch_num}..."
            sleep "$BATCH_DELAY"

            local release="ueransim-ues-batch${batch_num}"
            echo "[ues] Batch ${batch_num}: $this_batch UEs (MSISDN ${msisdn_start}..$(( deployed + this_batch )))"
            helm upgrade --install "$release" \
                oci://registry-1.docker.io/gradiant/ueransim-ues \
                --version 0.1.2 \
                --namespace open5gs \
                --set count="$this_batch" \
                --set initialMSISDN="$msisdn_str" \
                --set gnb.hostname=ueransim-gnb \
                --set mcc=999 --set mnc=70 \
                --set sst=1 --set "sd=0x111111" \
                --wait --timeout=3m 2>/dev/null || \
            helm upgrade --install "$release" \
                oci://registry-1.docker.io/gradiant/ueransim-ues \
                --version 0.1.2 \
                --namespace open5gs \
                --values https://gradiant.github.io/5g-charts/docs/open5gs-ueransim-gnb/gnb-ues-values.yaml \
                --set count="$this_batch" \
                --set initialMSISDN="$msisdn_str" \
                --set gnb.hostname=ueransim-gnb \
                --wait --timeout=3m

            deployed=$(( deployed + this_batch ))
            batch_num=$(( batch_num + 1 ))
        done
    fi

    echo "[ues] Scaled to $count UEs across $batch_num batch(es)"
    echo "[ues] Waiting 45s for PDU sessions to establish after final batch..."
    sleep 45
}

# wait_for_ue_sessions <count> [timeout_s]
# Polls active uesimtun interfaces across all UE pods until count >= target.
# (Open5GS 2.3.4 SMF does not expose :9090/metrics inside the pod.)
wait_for_ue_sessions() {
    local target="${1:-10}" timeout="${2:-240}"
    local grace=$(( target * 8 / 10 ))
    [[ "$grace" -lt 5 ]] && grace=5
    local deadline=$(( $(date +%s) + timeout ))
    echo -n "  [wait] Waiting for ${target} UE tunnels (accept ≥${grace})"

    _count_ue_tunnels() {
        local total=0 _pod _tuns
        while IFS= read -r _pod; do
            [[ -z "$_pod" ]] && continue
            _tuns=$(kubectl exec -n open5gs "$_pod" -- \
                ip link show 2>/dev/null | { grep -c uesimtun || true; })
            total=$(( total + ${_tuns:-0} ))
        done < <(kubectl get pods -n open5gs --no-headers 2>/dev/null \
            | grep -E "ueransim-gnb-ues|ueransim-ues-batch" | grep " Running " | awk '{print $1}')
        echo "$total"
    }

    local restarted=0
    while [[ $(date +%s) -lt $deadline ]]; do
        local val
        val=$(_count_ue_tunnels)
        if [[ "$val" -ge "$grace" ]]; then
            if [[ "$val" -ge "$target" ]]; then
                echo " OK (${val} tunnels)"
            else
                echo " OK (${val}/${target} tunnels, ≥80%)"
            fi
            return 0
        fi
        # If halfway through timeout and still below grace, restart CP + all UEs.
        if [[ "$restarted" -eq 0 && $(date +%s) -ge $(( deadline - timeout/2 )) && "$val" -lt "$grace" ]]; then
            echo ""
            echo "  [wait] Only ${val}/${target} tunnels after $((timeout/2))s — recovering CP + all UE deployments..."
            _restart_core_for_ue_recovery
            _restart_all_ue_deployments
            restarted=1
            echo -n "  [wait] Retrying"
        fi
        echo -n "."
        sleep 5
    done
    # First timeout: full CP + all UE restarts, then another wait window
    echo ""
    echo "  [wait] Timeout — restarting core NFs and all UE deployments..."
    _restart_core_for_ue_recovery
    _restart_all_ue_deployments
    local deadline2=$(( $(date +%s) + timeout ))
    echo -n "  [wait] Retry"
    while [[ $(date +%s) -lt $deadline2 ]]; do
        val=$(_count_ue_tunnels)
        if [[ "$val" -ge "$grace" ]]; then
            echo " OK (${val} tunnels after retry)"
            return 0
        fi
        echo -n "."
        sleep 5
    done
    echo " TIMEOUT (${val:-0}/${target} tunnels, need ≥${grace})" >&2
    return 1
}

# Rate-window warmup: discard first N seconds of each collection window so
# PromQL rate(...[2m]) queries are not biased at the window edge.
RATE_WARMUP_S="${RATE_WARMUP_S:-120}"

# Minimum active UE tunnels required by health_check.sh (override per experiment).
MIN_TUNNELS="${MIN_TUNNELS:-10}"

# _interval_index <1s|5s|15s|30s> — ordering for resume/skip logic
_interval_index() {
    case "$1" in
        1s)  echo 0 ;;
        5s)  echo 1 ;;
        15s) echo 2 ;;
        30s) echo 3 ;;
        *)   echo 99 ;;
    esac
}

# should_skip_run <out_dir> [interval] [run]
# Skips when: (a) already data_valid, or (b) before FROM_INTERVAL/FROM_RUN resume point.
should_skip_run() {
    local out_dir="$1" interval="${2:-}" run="${3:-1}"
    if [[ -f "$out_dir/meta.json" ]] && [[ "${SKIP_VALID_RUNS:-1}" == "1" ]]; then
        if python3 -c "import json,sys; d=json.load(open('$out_dir/meta.json')); sys.exit(0 if d.get('data_valid') is True else 1)" 2>/dev/null; then
            echo "  [skip] $out_dir — already valid"
            return 0
        fi
    fi
    if [[ -n "${FROM_INTERVAL:-}" ]]; then
        local ci fi
        ci=$(_interval_index "$interval")
        fi=$(_interval_index "$FROM_INTERVAL")
        if [[ "$ci" -lt "$fi" ]] || { [[ "$ci" -eq "$fi" ]] && [[ "$run" -lt "${FROM_RUN:-1}" ]]; }; then
            echo "  [skip] $out_dir — before resume point ${FROM_INTERVAL}/run_${FROM_RUN:-1}"
            return 0
        fi
    fi
    return 1
}

# prom_query_start <collection_start_ts>
# Returns the Prometheus query start (collection start + rate warmup).
prom_query_start() {
    echo $(( $1 + RATE_WARMUP_S ))
}

# setup_cluster_with_ues <count>
# Full cluster reset, provision subscribers, scale UERANSIM, wait for sessions.
setup_cluster_with_ues() {
    local count="${1:-50}"
    bash "$REPO_ROOT/cluster-start.sh"
    bash "$LIB_DIR/provision_ues.sh" "$count"
    # Always scale — cluster-start defaults to ues.count=2; counts ≤10 were skipped
    # before, leaving too few UE pods for wait_for_ue_sessions.
    scale_ues "$count"
    local wait_timeout=300
    [[ "$count" -ge 40 ]] && wait_timeout=420
    wait_for_ue_sessions "$count" "$wait_timeout"
}

# require_health_check <label> <out_file> [min_tunnels]
require_health_check() {
    local label="$1" out_file="$2"
    MIN_TUNNELS="${3:-${MIN_TUNNELS:-10}}"
    bash "$LIB_DIR/health_check.sh" "$label" "$out_file"
}

# mark_run_valid / mark_run_invalid — annotate meta.json data quality
mark_run_valid() {
    local out_dir="$1"
    python3 -c "
import json
p='$out_dir/meta.json'
d=json.load(open(p))
d['data_valid']=True
d.pop('invalid_reason', None)
json.dump(d,open(p,'w'),indent=2)
"
}

mark_run_invalid() {
    local out_dir="$1" reason="$2"
    python3 -c "
import json
p='$out_dir/meta.json'
d=json.load(open(p))
d['data_valid']=False
d['invalid_reason']='$reason'
json.dump(d,open(p,'w'),indent=2)
"
}

# validate_required_metrics <out_dir> <file1> [file2...]
# Returns 1 and marks run invalid if any required CSV is missing or empty.
validate_required_metrics() {
    local out_dir="$1"
    shift
    local missing=()
    for f in "$@"; do
        local csv="$out_dir/prometheus/$f"
        if [[ ! -f "$csv" ]] || [[ "$(wc -l < "$csv")" -le 1 ]]; then
            missing+=("$f")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "[validate] Missing required metrics: ${missing[*]}" >&2
        mark_run_invalid "$out_dir" "missing_metrics:${missing[*]}"
        return 1
    fi
    return 0
}

# collect_prometheus_extra <start> <end> <step> <out_dir> <label:query:file>...
collect_prometheus_extra() {
    local start="$1" end="$2" step="$3" out_dir="$4"
    shift 4
    python3 "$LIB_DIR/collect_prometheus.py" \
        --url "$PROM_URL" \
        --start "$start" \
        --end   "$end" \
        --step  "$step" \
        --out   "$out_dir" \
        --extra-metrics "$@"
}

# validate_ue_rtt <out_dir> [min_ok_fraction]
# Marks run invalid when ue_rtt.csv has too few successful pings.
validate_ue_rtt() {
    local out_dir="$1"
    local min_frac="${2:-0.5}"
    local rtt_file="$out_dir/ue_rtt.csv"
    if [[ ! -f "$rtt_file" ]]; then
        mark_run_invalid "$out_dir" "missing_ue_rtt.csv"
        return 1
    fi
    python3 -c "
import json, sys
import pandas as pd
p='$rtt_file'
df=pd.read_csv(p)
if 'status' in df.columns:
    ok=int((df['status']=='ok').sum())
    total=len(df)
else:
    col='rtt_ms' if 'rtt_ms' in df.columns else 'value'
    ok=int(df[col].apply(pd.to_numeric,errors='coerce').notna().sum())
    total=len(df)
frac=ok/total if total else 0.0
meta=json.load(open('$out_dir/meta.json'))
meta['rtt_ok_rows']=ok
meta['rtt_total_rows']=total
meta['rtt_ok_fraction']=round(frac,4)
with open('$out_dir/meta.json','w') as f: json.dump(meta,f,indent=2)
sys.exit(0 if frac >= $min_frac else 1)
" || {
        mark_run_invalid "$out_dir" "insufficient_valid_rtt"
        return 1
    }
    return 0
}

# ---------------------------------------------------------------------------
# Prometheus scrape interval reconfiguration
# ---------------------------------------------------------------------------

# set_prometheus_scrape_interval <interval>  e.g. "1s", "5s", "15s"
set_prometheus_scrape_interval() {
    local interval="$1"
    echo "[prom] Scrape interval set to $interval"
    helm upgrade kube-prom prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --reuse-values \
        --set prometheus.prometheusSpec.scrapeInterval="$interval" \
        --wait --timeout=3m 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Data collection wrappers
# ---------------------------------------------------------------------------

# collect_prometheus <start_ts> <end_ts> <step> <out_dir>
collect_prometheus() {
    local start="$1" end="$2" step="$3" out_dir="$4"
    mkdir -p "$out_dir"
    python3 "$LIB_DIR/collect_prometheus.py" \
        --url "$PROM_URL" \
        --start "$start" \
        --end   "$end" \
        --step  "$step" \
        --out   "$out_dir"
}

# collect_jaeger <start_ts> <end_ts> <out_dir>
collect_jaeger() {
    local start="$1" end="$2" out_dir="$3"
    mkdir -p "$out_dir"
    python3 "$LIB_DIR/collect_jaeger.py" \
        --url   "$JAEGER_URL" \
        --start "$start" \
        --end   "$end" \
        --out   "$out_dir"
}

# collect_loki <start_ts> <end_ts> <out_dir>
collect_loki() {
    local start="$1" end="$2" out_dir="$3"
    mkdir -p "$out_dir"
    python3 "$LIB_DIR/collect_loki.py" \
        --url   "$LOKI_URL" \
        --start "$start" \
        --end   "$end" \
        --out   "$out_dir"
}

# collect_events <start_ts> <end_ts> <out_dir>
collect_events() {
    local start="$1" end="$2" out_dir="$3"
    mkdir -p "$out_dir"
    python3 "$LIB_DIR/collect_events.py" \
        --namespace open5gs \
        --start "$start" \
        --end   "$end" \
        --out   "$out_dir"
}

# collect_nrf <out_dir> — snapshots current NRF instance counts (no time window)
collect_nrf() {
    local out_dir="$1"
    mkdir -p "$out_dir"
    python3 "$LIB_DIR/collect_nrf.py" \
        --namespace open5gs \
        --out   "$out_dir"
}

# ---------------------------------------------------------------------------
# Experiment metadata
# ---------------------------------------------------------------------------

log_experiment_start() {
    local name="$1" out_dir="$2"
    mkdir -p "$out_dir"
    echo "{\"experiment\": \"$name\", \"started_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
        > "$out_dir/meta.json"
    echo "[meta] $name started"
}

log_experiment_end() {
    local out_dir="$1"
    local meta="$out_dir/meta.json"
    if [[ -f "$meta" ]]; then
        python3 -c "
import json, datetime
with open('$meta') as f: d = json.load(f)
d['ended_at'] = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
with open('$meta', 'w') as f: json.dump(d, f, indent=2)
" 2>/dev/null || true
    fi
}

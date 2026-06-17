#!/usr/bin/env bash
# experiments/lib/configure_telemetry.sh
#
# Sourced helper functions to enable/disable telemetry stack components
# for the A-observability-overhead experiments.  Each function is idempotent.
#
# Components managed:
#   Prometheus server    — StatefulSet prometheus-kube-prom-kube-prometheus-prometheus
#   Beyla DaemonSet      — DaemonSet beyla in open5gs namespace
#   Open5GS NF metrics   — helm upgrade open5gs with metrics.enabled=false/true
#
# Sourcing convention:
#   source "$SCRIPT_DIR/../lib/configure_telemetry.sh"

# ---------------------------------------------------------------------------
# Prometheus server
# ---------------------------------------------------------------------------

# disable_prometheus_server — pause the Prometheus StatefulSet so it stops
# scraping and consuming CPU/memory.  The Prometheus Operator CR is patched
# to paused=true which is the supported way to stop the StatefulSet without
# fighting the operator reconciler.
disable_prometheus_server() {
    echo "[telemetry] Disabling Prometheus server..."
    # Pause the Prometheus CR so the operator doesn't fight us, then scale to 0
    kubectl patch prometheus -n monitoring \
        kube-prom-kube-prometheus-prometheus \
        --type=merge \
        -p '{"spec":{"paused":true}}' 2>/dev/null || true
    # Scale the StatefulSet to 0 (the paused CR prevents the operator from scaling it back)
    kubectl scale statefulset -n monitoring \
        prometheus-kube-prom-kube-prometheus-prometheus --replicas=0 2>/dev/null || true

    local deadline=$(($(date +%s) + 60))
    until ! kubectl get pod -n monitoring \
            prometheus-kube-prom-kube-prometheus-prometheus-0 \
            &>/dev/null; do
        sleep 3
        [[ $(date +%s) -gt $deadline ]] && break
    done
    echo "[telemetry] Prometheus server stopped"
}

# enable_prometheus_server — unpause the Prometheus StatefulSet
enable_prometheus_server() {
    echo "[telemetry] Enabling Prometheus server..."
    kubectl patch prometheus -n monitoring \
        kube-prom-kube-prometheus-prometheus \
        --type=merge \
        -p '{"spec":{"paused":false}}' 2>/dev/null || true
    kubectl scale statefulset -n monitoring \
        prometheus-kube-prom-kube-prometheus-prometheus --replicas=1 2>/dev/null || true

    # Wait for the StatefulSet rollout to complete
    kubectl rollout status statefulset -n monitoring \
        prometheus-kube-prom-kube-prometheus-prometheus --timeout=120s 2>/dev/null || true

    # Wait for the pod to become Ready (readinessProbe) before declaring success.
    # Prometheus can take 30-60s to load its TSDB after the container starts.
    echo -n "  [prom] Waiting for Prometheus pod readiness..."
    local deadline=$(($(date +%s) + 120))
    until kubectl get pod -n monitoring \
            prometheus-kube-prom-kube-prometheus-prometheus-0 \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
            | grep -q "True"; do
        sleep 5
        echo -n "."
        [[ $(date +%s) -gt $deadline ]] && { echo " TIMEOUT (continuing)"; break; }
    done
    echo " ready"
    echo "[telemetry] Prometheus server running"
}

# ---------------------------------------------------------------------------
# Beyla eBPF DaemonSet
# ---------------------------------------------------------------------------

# disable_beyla — suspend Beyla by patching in a nodeSelector that matches
# no node.  This terminates all Beyla pods without deleting the DaemonSet
# resource (preserving RBAC and PodMonitor objects).
disable_beyla() {
    echo "[telemetry] Disabling Beyla DaemonSet..."
    # Full replace of nodeSelector to an unmatchable label (no merge)
    kubectl patch daemonset beyla -n open5gs \
        --type=json \
        -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"beyla-enabled":"false"}}]' \
        2>/dev/null || true

    # Wait for all Beyla pods to terminate
    local deadline=$(($(date +%s) + 120))
    until [[ $(kubectl get pods -n open5gs -l app=beyla --no-headers 2>/dev/null \
        | grep -c " Running " || true) -eq 0 ]]; do
        sleep 5
        [[ $(date +%s) -gt $deadline ]] && break
    done
    echo "[telemetry] Beyla DaemonSet suspended (no pods running)"
}

# enable_beyla — clear the unmatchable nodeSelector so Beyla pods schedule on
# all nodes.  (kind nodes are not labelled beyla-target=true.)
enable_beyla() {
    echo "[telemetry] Enabling Beyla DaemonSet..."
    kubectl patch daemonset beyla -n open5gs \
        --type=json \
        -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{}}]' \
        2>/dev/null || true

    # Wait for at least one Beyla pod to be Running
    local deadline=$(($(date +%s) + 120))
    until [[ $(kubectl get pods -n open5gs -l app=beyla --no-headers 2>/dev/null \
        | grep -c " Running " || true) -ge 1 ]]; do
        sleep 5
        [[ $(date +%s) -gt $deadline ]] && { echo "[telemetry] WARN: Beyla pod not Running after 120s"; break; }
    done
    echo "[telemetry] Beyla DaemonSet running"
}

# set_beyla_sampling_rate <rate>
# rate: "100" | "50" | "10"  (percent, integer)
# Maps to OTEL_TRACES_SAMPLER:
#   100 → always_on
#   50  → traceidratio with OTEL_TRACES_SAMPLER_ARG=0.5
#   10  → traceidratio with OTEL_TRACES_SAMPLER_ARG=0.1
set_beyla_sampling_rate() {
    local rate="${1:-100}"
    local sampler sampler_arg=""

    case "$rate" in
        100) sampler="always_on" ;;
        50)  sampler="traceidratio"; sampler_arg="0.5" ;;
        10)  sampler="traceidratio"; sampler_arg="0.1" ;;
        *)
            echo "[telemetry] WARN: unknown Beyla sampling rate '$rate', defaulting to always_on"
            sampler="always_on"
            ;;
    esac

    echo "[telemetry] Setting Beyla sampling: $sampler (rate=${rate}%)"

    local patch
    if [[ -n "$sampler_arg" ]]; then
        patch=$(cat <<EOF
{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "beyla",
          "env": [
            {"name": "OTEL_TRACES_SAMPLER",     "value": "${sampler}"},
            {"name": "OTEL_TRACES_SAMPLER_ARG",  "value": "${sampler_arg}"}
          ]
        }]
      }
    }
  }
}
EOF
)
    else
        patch=$(cat <<EOF
{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "beyla",
          "env": [
            {"name": "OTEL_TRACES_SAMPLER",     "value": "${sampler}"},
            {"name": "OTEL_TRACES_SAMPLER_ARG",  "value": ""}
          ]
        }]
      }
    }
  }
}
EOF
)
    fi

    kubectl patch daemonset beyla -n open5gs \
        --type=strategic -p "$patch" 2>/dev/null || true

    kubectl rollout status daemonset beyla -n open5gs --timeout=90s 2>/dev/null || true
    echo "[telemetry] Beyla sampling rate set to ${rate}%"
}

# ---------------------------------------------------------------------------
# Open5GS NF metrics endpoints
# ---------------------------------------------------------------------------
#
# Rather than a slow helm upgrade (which restarts pods), we achieve the same
# isolation goal by suspending the three open5gs ServiceMonitor objects that
# tell Prometheus to scrape the NF metrics ports.  Prometheus will stop
# scraping within one scrape interval; no NF pods are restarted.
#
# Only AMF, SMF, and UPF expose metrics in the current chart version
# (open5gs-2.3.4 via gradiantcharts/open5gs 2.3.4).

# All 12 5G SA NFs: 4 have chart ServiceMonitor support, 8 added by
# kind/enable-extra-nf-metrics.sh (NRF, AUSF, BSF, UDM, UDR, SCP, NSSF, SEPP).
_OPEN5GS_SERVICE_MONITORS=(
    open5gs-amf open5gs-smf open5gs-upf open5gs-pcf
    open5gs-nrf open5gs-ausf open5gs-bsf open5gs-udm
    open5gs-udr open5gs-scp open5gs-nssf open5gs-sepp
)

disable_open5gs_metrics() {
    echo "[telemetry] Suspending Open5GS ServiceMonitors (stops Prometheus scraping NFs)..."
    for sm in "${_OPEN5GS_SERVICE_MONITORS[@]}"; do
        kubectl patch servicemonitor "$sm" -n open5gs \
            --type=json \
            -p '[{"op":"replace","path":"/spec/selector/matchLabels","value":{"scraping-disabled":"true"}}]' \
            2>/dev/null || true
    done
    echo "[telemetry] Open5GS ServiceMonitors suspended (NF scraping disabled)"
}

enable_open5gs_metrics() {
    echo "[telemetry] Restoring Open5GS ServiceMonitors..."
    # Restore the original selector: {component: metrics, instance: open5gs, name: <nf>}
    for sm in "${_OPEN5GS_SERVICE_MONITORS[@]}"; do
        # sm = "open5gs-amf" → nf_short = "amf"
        local nf_short="${sm#open5gs-}"
        kubectl patch servicemonitor "$sm" -n open5gs \
            --type=json \
            -p "[{\"op\":\"replace\",\"path\":\"/spec/selector/matchLabels\",\"value\":{\"app.kubernetes.io/component\":\"metrics\",\"app.kubernetes.io/instance\":\"open5gs\",\"app.kubernetes.io/name\":\"${nf_short}\"}}]" \
            2>/dev/null || true
    done
    echo "[telemetry] Open5GS ServiceMonitors restored"
}

# enable_specific_nf_metrics <nf> [<nf> ...]
# Disables ALL Open5GS ServiceMonitors first, then re-enables only the named
# ones.  Use this when you want to control monitoring scope per-NF.
# Example: enable_specific_nf_metrics amf
#          enable_specific_nf_metrics amf smf
enable_specific_nf_metrics() {
    if [[ $# -eq 0 ]]; then
        echo "[telemetry] WARN: enable_specific_nf_metrics called with no arguments — disabling all"
        disable_open5gs_metrics
        return
    fi
    echo "[telemetry] Enabling NF metrics for: $*"
    disable_open5gs_metrics
    for nf in "$@"; do
        kubectl patch servicemonitor "open5gs-${nf}" -n open5gs \
            --type=json \
            -p "[{\"op\":\"replace\",\"path\":\"/spec/selector/matchLabels\",\"value\":{\"app.kubernetes.io/component\":\"metrics\",\"app.kubernetes.io/instance\":\"open5gs\",\"app.kubernetes.io/name\":\"${nf}\"}}]" \
            2>/dev/null || true
    done
    echo "[telemetry] ServiceMonitors enabled for: $*"
}

# ---------------------------------------------------------------------------
# Beyla NF-scope control  (used by experiment 05 scalability sweep)
# ---------------------------------------------------------------------------
#
# enable_specific_nf_beyla restricts eBPF instrumentation to named NFs by
# setting BEYLA_EXECUTABLE_NAME (pipe-separated process names) and clearing
# the port-based filter.  A DaemonSet rollout is triggered automatically.
#
# Open5GS daemon names follow the pattern: open5gs-{nf}d
#   amf → open5gs-amfd   smf → open5gs-smfd   upf → open5gs-upfd
#   pcf → open5gs-pcfd   nrf → open5gs-nrfd   ausf → open5gs-ausfd
#   bsf → open5gs-bsfd   udm → open5gs-udmd   udr → open5gs-udrd
#   scp → open5gs-scpd   nssf → open5gs-nssfd  sepp → open5gs-seppd

enable_specific_nf_beyla() {
    if [[ $# -eq 0 ]]; then
        echo "[telemetry] WARN: enable_specific_nf_beyla called with no arguments"
        return
    fi
    local pattern=""
    for nf in "$@"; do
        local exec="open5gs-${nf}d"
        [[ -n "$pattern" ]] && pattern="${pattern}|${exec}" || pattern="$exec"
    done
    echo "[telemetry] Scoping Beyla to NFs: $* (executable pattern: $pattern)"
    # Ensure Beyla is schedulable (clear any unmatchable nodeSelector first)
    kubectl patch daemonset beyla -n open5gs \
        --type=json \
        -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{}}]' \
        2>/dev/null || true
    # Clear port filter, set executable filter, trigger rollout
    kubectl set env daemonset/beyla -n open5gs \
        BEYLA_EXECUTABLE_NAME="$pattern" \
        OTEL_EBPF_OPEN_PORT="" \
        BEYLA_OPEN_PORT="" 2>/dev/null || true
    local wait_s="${BEYLA_ROLLOUT_WAIT:-90}"
    kubectl rollout status daemonset/beyla -n open5gs --timeout="${wait_s}s" 2>/dev/null || true
    echo "[telemetry] Beyla now instrumenting: $*"
}

# restore_beyla_full_scope — remove executable filter and restore port-based
# watch (port 7777 = all Open5GS SBI processes).
restore_beyla_full_scope() {
    echo "[telemetry] Restoring Beyla to full scope (port 7777)..."
    # The trailing '-' removes an env var; the others set the port filter back.
    kubectl set env daemonset/beyla -n open5gs \
        BEYLA_EXECUTABLE_NAME- \
        OTEL_EBPF_OPEN_PORT=7777 \
        BEYLA_OPEN_PORT=7777 2>/dev/null || true
    local wait_s="${BEYLA_ROLLOUT_WAIT:-90}"
    kubectl rollout status daemonset/beyla -n open5gs --timeout="${wait_s}s" 2>/dev/null || true
    echo "[telemetry] Beyla scope restored to all port-7777 processes"
}

# ---------------------------------------------------------------------------
# Convenience: restore the full production telemetry stack
# ---------------------------------------------------------------------------

restore_production_telemetry() {
    echo "[telemetry] Restoring full production telemetry stack..."
    enable_prometheus_server
    enable_beyla
    enable_open5gs_metrics
    restore_beyla_full_scope
    set_beyla_sampling_rate 100
    echo "[telemetry] Production telemetry stack restored"
}

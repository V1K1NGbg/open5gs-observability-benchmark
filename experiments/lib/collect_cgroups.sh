#!/usr/bin/env bash
# experiments/lib/collect_cgroups.sh
#
# Collect CPU and memory metrics from the kind worker nodes by running
# a sampling loop via `docker exec` on each node container.
#
# This is the out-of-band measurement path for Experiment 01 (no-telemetry
# baseline) where Prometheus is disabled. No pods are deployed.
#
# Output files (written to <out_dir>/):
#   <node>_node_cpu_idle.csv     — per-CPU idle/total ticks from /proc/stat
#   <node>_node_memory.csv       — MemAvailable / MemTotal from /proc/meminfo
#   <node>_cgroup_samples.csv    — kubepods cgroup cpu.stat / memory.current
#
# Usage:
#   bash collect_cgroups.sh <duration_seconds> <sample_interval_seconds> <out_dir>

set -euo pipefail

DURATION="${1:-300}"
INTERVAL="${2:-5}"
OUT_DIR="${3:-/tmp/cgroup_data}"
mkdir -p "$OUT_DIR"

echo "[cgroups] Starting ${DURATION}s collection (${INTERVAL}s interval) → $OUT_DIR"

# Find all kind worker nodes (Docker container names)
NODES=$(docker ps --filter "label=io.x-k8s.kind.role=worker" --format "{{.Names}}" 2>/dev/null || true)
if [[ -z "$NODES" ]]; then
    echo "[cgroups] WARN: no kind worker containers found, skipping cgroup collection"
    exit 0
fi

# Spawn a background sampler for each node
PIDS=()
for NODE in $NODES; do
    NODE_SAFE=$(echo "$NODE" | tr '/' '_' | tr ':' '_')
    CPU_OUT="$OUT_DIR/${NODE_SAFE}_node_cpu_idle.csv"
    MEM_OUT="$OUT_DIR/${NODE_SAFE}_node_memory.csv"
    CG_OUT="$OUT_DIR/${NODE_SAFE}_cgroup_samples.csv"

    echo "timestamp_s,cpu,idle_ticks,total_ticks" > "$CPU_OUT"
    echo "timestamp_s,mem_total_bytes,mem_available_bytes" > "$MEM_OUT"
    echo "timestamp_s,cgroup_path,cpu_usage_usec,memory_current_bytes" > "$CG_OUT"

    (
        END_TS=$(( $(date +%s) + DURATION ))
        while [[ $(date +%s) -lt $END_TS ]]; do
            TS=$(date +%s)

            # /proc/stat — CPU idle ticks
            docker exec "$NODE" cat /proc/stat 2>/dev/null \
            | awk -v ts="$TS" '/^cpu[0-9 ]/{
                name=$1
                idle=$5
                total=0; for(i=2;i<=NF;i++) total+=$i
                print ts "," name "," idle "," total
            }' >> "$CPU_OUT" || true

            # /proc/meminfo — MemTotal, MemAvailable (in bytes)
            docker exec "$NODE" grep -E "^(MemTotal|MemAvailable):" /proc/meminfo 2>/dev/null \
            | awk -v ts="$TS" '
                /MemTotal/    { tot=$2*1024 }
                /MemAvailable/{ avl=$2*1024 }
                END { print ts "," tot "," avl }
            ' >> "$MEM_OUT" || true

            # cgroup v2: sample kubepods cpu.stat + memory.current
            # Walk a few levels deep to catch pod-level cgroups without
            # flooding with per-container entries.
            docker exec "$NODE" sh -c '
                CROOT=""
                [ -d /sys/fs/cgroup/kubepods.slice ]                      && CROOT=/sys/fs/cgroup/kubepods.slice
                [ -d /sys/fs/cgroup/kubepods ]                            && CROOT=/sys/fs/cgroup/kubepods
                [ -d /sys/fs/cgroup/kubelet.slice/kubelet-kubepods.slice ] && CROOT=/sys/fs/cgroup/kubelet.slice/kubelet-kubepods.slice
                [ -z "$CROOT" ] && exit 0
                find "$CROOT" -maxdepth 4 -name "cpu.stat" 2>/dev/null | while read f; do
                    d=$(dirname "$f")
                    cpu_usec=$(grep "^usage_usec " "$f" 2>/dev/null | awk "{print \$2}" || echo 0)
                    mem_cur=0
                    [ -f "$d/memory.current" ] && mem_cur=$(cat "$d/memory.current" 2>/dev/null || echo 0)
                    echo "'"$TS"',$d,$cpu_usec,$mem_cur"
                done
            ' 2>/dev/null >> "$CG_OUT" || true

            sleep "$INTERVAL"
        done
        echo "[cgroups] Node $NODE done → $OUT_DIR"
    ) &
    PIDS+=($!)
done

# Wait for all node samplers to finish
for pid in "${PIDS[@]}"; do
    wait "$pid" || true
done

echo "[cgroups] All nodes complete → $OUT_DIR"

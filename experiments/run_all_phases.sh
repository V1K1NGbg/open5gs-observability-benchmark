#!/usr/bin/env bash
# experiments/run_all_phases.sh
#
# Top-level orchestrator. Runs all three experiment groups in sequence.
#
# Groups:
#   A — Observability overhead  (no-telemetry baseline, Prometheus, Beyla, scaling)
#   B — Log strategies          (CPU, storage, visibility, strategy×scale)
#   C — Fault detection         (18 faults, full 5-signal collection)
#
# Usage:
#   bash run_all_phases.sh                  # run A → B → C
#   bash run_all_phases.sh --from B         # skip A, start from B
#   bash run_all_phases.sh --from C         # skip A+B, run only C
#
# Estimated total runtime:
#   600/300/300 fault durations: ~21 h
#   120/300/120 fault durations: ~17 h
#
# Run in a tmux/screen session.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FROM_GROUP="A"
if [[ "${1:-}" == "--from" && -n "${2:-}" ]]; then
    FROM_GROUP="$2"
fi

run_group() {
    local label="$1" script="$2"
    if [[ "$FROM_GROUP" > "$label" ]]; then
        echo "[skip] Group $label"
        return
    fi
    echo ""
    echo "████████████████████████████████████████████████████████████"
    echo " GROUP $label"
    echo "████████████████████████████████████████████████████████████"
    bash "$script"
    echo ""
    echo "[group $label done] Sleeping 2 minutes before next group..."
    sleep 120
}

run_group A "$SCRIPT_DIR/A/run_all.sh"
run_group B "$SCRIPT_DIR/B-log-strategies/run_all.sh"
run_group C "$SCRIPT_DIR/C-fault-detection/run_all.sh"

echo ""
echo "████████████████████████████████████████████████████████████"
echo " ALL GROUPS COMPLETE"
echo " Data in: $REPO_ROOT/data/experiments/"
echo "████████████████████████████████████████████████████████████"

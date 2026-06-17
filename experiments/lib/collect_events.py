#!/usr/bin/env python3
"""
experiments/lib/collect_events.py

Snapshot Kubernetes events in a namespace, filter by phase time window,
strip known background noise, and write k8s_events.json.

Usage:
    python3 collect_events.py \
        --namespace open5gs \
        --start <unix_ts> --end <unix_ts> \
        --out /path/to/output/dir
"""

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Background noise to drop (same filters as Boyan's main collect.py)
NOISE_OBJECTS = ("open5gs-populate",)
NOISE_REASONS = ("FailedGetScale",)


def parse_iso(ts: str):
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None


def collect(namespace: str, start_ts: int, end_ts: int) -> list:
    start_dt = datetime.fromtimestamp(start_ts, tz=timezone.utc)
    end_dt   = datetime.fromtimestamp(end_ts,   tz=timezone.utc)
    try:
        raw = subprocess.check_output(
            ["kubectl", "get", "events", "-n", namespace,
             "-o", "json", "--sort-by=.lastTimestamp"],
            timeout=15, text=True,
        )
    except subprocess.CalledProcessError as e:
        print(f"  [events] kubectl failed: {e}", file=sys.stderr)
        return []
    except subprocess.TimeoutExpired:
        print("  [events] kubectl timeout", file=sys.stderr)
        return []

    all_events = json.loads(raw).get("items", [])
    out = []
    for ev in all_events:
        ts_str = ev.get("lastTimestamp") or ev.get("eventTime", "")
        ts = parse_iso(ts_str)
        if ts is None or not (start_dt <= ts <= end_dt):
            continue
        obj_name = ev.get("involvedObject", {}).get("name", "")
        reason = ev.get("reason", "")
        if any(noise in obj_name for noise in NOISE_OBJECTS):
            continue
        if reason in NOISE_REASONS:
            continue
        out.append({
            "time":    ts_str,
            "reason":  reason,
            "message": ev.get("message", ""),
            "object":  obj_name,
            "kind":    ev.get("involvedObject", {}).get("kind", ""),
            "type":    ev.get("type", ""),  # Normal / Warning
            "count":   ev.get("count", 1),
        })
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--namespace", default="open5gs")
    parser.add_argument("--start", type=int, required=True, help="Window start, unix seconds")
    parser.add_argument("--end",   type=int, required=True, help="Window end,   unix seconds")
    parser.add_argument("--out",   required=True)
    args = parser.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    events = collect(args.namespace, args.start, args.end)
    (out_dir / "k8s_events.json").write_text(json.dumps(events, indent=2))

    warnings = [e for e in events if e["type"] == "Warning"]
    print(f"  [events] k8s_events.json: {len(events)} total, {len(warnings)} warnings")

    notable = {"OOMKilling", "Killing", "BackOff", "Failed", "Evicted", "Unhealthy"}
    for ev in events:
        if ev["reason"] in notable:
            msg = ev["message"][:80]
            print(f"    [{ev['reason']}] {ev['object']}: {msg}")


if __name__ == "__main__":
    main()

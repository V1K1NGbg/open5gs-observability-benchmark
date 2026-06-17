#!/usr/bin/env python3
"""
experiments/lib/collect_loki.py

Query Loki HTTP API for a fixed set of LogQL queries over a time window
and write each query result to a CSV file (one row per log line).

Results are fetched with cursor-based pagination (small per-page limit),
so no single request is large enough to hit Loki's server-side
max_entries_limit_per_query cap or time out — this works regardless of
log volume and without depending on the cluster-start cap patch.

Beyla pods are excluded at the selector level: at DEBUG they emit ~85%
of the namespace's log volume (eBPF name-resolution chatter) and carry
zero fault-atlas signal — Beyla's signal is its Prometheus metrics and
traces, collected separately. ueransim is kept (UE/gNB failure logs are
signal).

Usage:
    python3 collect_loki.py \
        --url http://127.0.0.1:3100 \
        --start <unix_ts> --end <unix_ts> \
        --out /path/to/output/dir
"""

import argparse
import csv
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

_SEL = '{namespace="open5gs", pod!~"beyla-.+"}'

# (output_filename, LogQL query)
LOKI_QUERIES = [
    ("all.csv",
     _SEL),
    ("errors.csv",
     _SEL + ' |~ "(?i)(error|exception|refused|failed|fatal|oom|killed)"'),
    ("nrf_lifecycle.csv",
     _SEL + ' |~ "(?i)(heartbeat|de-registered|Retry registration|NF registered|NF de-registered)"'),
    ("ue_failures.csv",
     _SEL + ' |~ "(?i)(PAYLOAD_NOT_FORWARDED|Registration reject|UE_IDENTITY|FIVEG_SERVICES|Cannot receive SBI)"'),
    ("scp_routing.csv",
     _SEL + ' |~ "(?i)(Connection timer expired|Connection refused|Failed to connect|response_handler.*failed)"'),
]

PER_PAGE = 5000     # entries per request — under Loki's default cap, fast
MAX_PAGES = 5000    # infinite-loop guard (PER_PAGE*MAX_PAGES = 25M lines)


def _request(url: str, query: str, start_ns: int, end_ns: int) -> dict:
    params = urllib.parse.urlencode({
        "query":     query,
        "start":     start_ns,
        "end":       end_ns,
        "limit":     PER_PAGE,
        "direction": "forward",
    })
    req_url = f"{url}/loki/api/v1/query_range?{params}"
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req_url, timeout=60) as resp:
                return json.load(resp)
        except Exception as e:
            if attempt == 2:
                print(f"  [WARN] Loki request failed: {e}", file=sys.stderr)
                return None
            time.sleep(2)
    return None


def _streams_to_tuples(data: dict) -> list:
    out = []
    for stream in (data.get("data", {}).get("result", []) or []):
        labels = stream.get("stream", {}) or {}
        pod = labels.get("pod", "")
        container = labels.get("container", "")
        app = labels.get("app", "") or labels.get("app_kubernetes_io_name", "")
        for ts_ns, line in stream.get("values", []):
            out.append((int(ts_ns), pod, container, app, line))
    return out


def fetch_paged(url: str, query: str, start_ns: int, end_ns: int):
    """Cursor-paginate forward through the window. Returns (rows, truncated)."""
    rows = []
    seen = set()
    cursor = start_ns
    truncated = False
    for _ in range(MAX_PAGES):
        data = _request(url, query, cursor, end_ns)
        if data is None:
            truncated = True
            break
        tup = _streams_to_tuples(data)
        if not tup:
            break
        tup.sort(key=lambda t: t[0])
        new = 0
        for ts, pod, container, app, line in tup:
            key = (ts, pod, line)
            if key in seen:
                continue
            seen.add(key)
            rows.append({"timestamp_ns": ts, "pod": pod,
                         "container": container, "app": app, "line": line})
            new += 1
        if len(tup) < PER_PAGE:
            break                       # window exhausted
        max_ts = tup[-1][0]
        if max_ts <= cursor and new == 0:
            # >PER_PAGE entries share one ns: skip past it (rare; tiny gap)
            print(f"  [WARN] paging stalled at {cursor}; advancing 1ns",
                  file=sys.stderr)
            cursor = max_ts + 1
        else:
            cursor = max_ts             # inclusive; dedupe handles overlap
    else:
        truncated = True                # hit MAX_PAGES

    rows.sort(key=lambda r: r["timestamp_ns"])
    return rows, truncated


def write_csv(rows: list, out_path: Path):
    fieldnames = ["timestamp_ns", "pod", "container", "app", "line"]
    with open(out_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    print(f"  [loki] {out_path.name}: {len(rows)} lines")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:3100")
    parser.add_argument("--start", type=int, required=True, help="Window start, unix seconds")
    parser.add_argument("--end",   type=int, required=True, help="Window end,   unix seconds")
    parser.add_argument("--out",   required=True)
    args = parser.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    start_ns = args.start * 1_000_000_000
    end_ns   = args.end   * 1_000_000_000

    for fname, query in LOKI_QUERIES:
        rows, truncated = fetch_paged(args.url, query, start_ns, end_ns)
        write_csv(rows, out_dir / fname)
        if truncated:
            print(f"  [loki] WARNING: {fname} incomplete "
                  f"(request failed or hit {MAX_PAGES}-page guard)",
                  file=sys.stderr)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
experiments/lib/collect_jaeger.py

Query Jaeger HTTP API for all traces in a time window, flatten spans,
and write spans_flat.csv + summary.json.

Usage:
    python3 collect_jaeger.py \
        --url http://127.0.0.1:16686 \
        --start <unix_ts> --end <unix_ts> \
        --out /path/to/output/dir
"""

import argparse
import csv
import json
import sys
import time
import urllib.request
import urllib.parse
from pathlib import Path
from collections import defaultdict

# Skip Jaeger's own self-trace service and infrastructure noise.
SERVICE_BLOCKLIST = {"jaeger", "jaeger-query", "jaeger-collector"}


def discover_services(jaeger_url: str) -> list:
    """Fetch the live list of services from Jaeger. Beyla autodetect strips
    the deployment prefix, so service names are 'amf', 'smf', etc. — not
    'open5gs-amf'. Hardcoding the list breaks on naming convention drift."""
    data = jaeger_get(jaeger_url, "/api/services", {})
    return [s for s in data.get("data", []) if s not in SERVICE_BLOCKLIST]


def jaeger_get(url: str, path: str, params: dict) -> dict:
    qs = urllib.parse.urlencode(params) if params else ""
    req_url = f"{url}{path}?{qs}" if qs else f"{url}{path}"
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req_url, timeout=120) as resp:
                return json.load(resp)
        except Exception as e:
            if attempt == 2:
                print(f"  [WARN] Jaeger request failed: {e}", file=sys.stderr)
                return {}
            time.sleep(2)
    return {}


def collect_service(jaeger_url: str, service: str, start_us: int, end_us: int) -> list:
    data = jaeger_get(jaeger_url, "/api/traces", {
        "service": service,
        "start": start_us,
        "end": end_us,
        "limit": 20000,
    })
    return data.get("data", [])


def flatten_spans(traces: list, service: str) -> list:
    rows = []
    for trace in traces:
        trace_id = trace.get("traceID", "")
        for span in trace.get("spans", []):
            tags = {t["key"]: t["value"] for t in span.get("tags", [])}
            error = "1" if tags.get("error") == "true" or tags.get("otel.status_code") == "ERROR" else "0"
            rows.append({
                "trace_id": trace_id,
                "span_id": span.get("spanID", ""),
                "service": service,
                "operation": span.get("operationName", ""),
                "start_us": span.get("startTime", 0),
                "duration_us": span.get("duration", 0),
                "error": error,
            })
    return rows


def summarise(spans: list) -> dict:
    by_service = defaultdict(list)
    for s in spans:
        by_service[s["service"]].append(s)

    summary = {}
    for svc, svc_spans in by_service.items():
        durations = [int(s["duration_us"]) for s in svc_spans]
        errors = sum(1 for s in svc_spans if s["error"] == "1")
        durations_sorted = sorted(durations)
        n = len(durations_sorted)
        summary[svc] = {
            "span_count": n,
            "error_count": errors,
            "error_rate": round(errors / n, 4) if n > 0 else 0,
            "duration_us_mean": round(sum(durations) / n, 1) if n > 0 else 0,
            "duration_us_p50": durations_sorted[int(n * 0.50)] if n > 0 else 0,
            "duration_us_p95": durations_sorted[int(n * 0.95)] if n > 0 else 0,
            "duration_us_p99": durations_sorted[int(n * 0.99)] if n > 0 else 0,
        }
    return summary


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:16686")
    parser.add_argument("--start", type=int, required=True)
    parser.add_argument("--end", type=int, required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    start_us = args.start * 1_000_000
    end_us = args.end * 1_000_000

    services = discover_services(args.url)
    if not services:
        print("  [jaeger] WARN: no services in /api/services", file=sys.stderr)

    all_spans = []
    for svc in services:
        traces = collect_service(args.url, svc, start_us, end_us)
        spans = flatten_spans(traces, svc)
        all_spans.extend(spans)
        if spans:
            print(f"  [jaeger] {svc}: {len(spans)} spans from {len(traces)} traces")

    if all_spans:
        fieldnames = ["trace_id", "span_id", "service", "operation", "start_us", "duration_us", "error"]
        with open(out_dir / "spans_flat.csv", "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(all_spans)
        print(f"  [jaeger] spans_flat.csv: {len(all_spans)} total spans")
    else:
        print("  [jaeger] No spans collected", file=sys.stderr)

    summary = summarise(all_spans)
    with open(out_dir / "summary.json", "w") as f:
        json.dump(summary, f, indent=2)
    print(f"  [jaeger] summary.json: {len(summary)} services")


if __name__ == "__main__":
    main()

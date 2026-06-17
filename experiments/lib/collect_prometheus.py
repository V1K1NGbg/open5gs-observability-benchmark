#!/usr/bin/env python3
"""
experiments/lib/collect_prometheus.py

Query Prometheus HTTP API for a set of standard metrics over a time window
and write each metric to a CSV file.

Usage:
    python3 collect_prometheus.py \
        --url http://127.0.0.1:9090 \
        --start <unix_ts> --end <unix_ts> \
        --step 5s \
        --out /path/to/output/dir \
        [--extra-metrics "label:query:filename.csv" ...]
"""

import argparse
import csv
import os
import sys
import time
import urllib.request
import urllib.parse
import json
from pathlib import Path

# ---------------------------------------------------------------------------
# Standard metrics collected for every experiment window
# ---------------------------------------------------------------------------
STANDARD_METRICS = [
    # (output_filename, promql_query)
    ("container_cpu_usage_rate.csv",
     'rate(container_cpu_usage_seconds_total{namespace="open5gs",container!=""}[2m])'),
    ("container_memory_working_set_bytes.csv",
     'container_memory_working_set_bytes{namespace="open5gs",container!=""}'),
    # cAdvisor in newer kube-prometheus-stack dropped *_seconds_total in favour
    # of period counters. Throttle ratio = throttled-periods / total-periods,
    # bounded 0..1; spikes to ~1 when a container saturates its CPU limit.
    ("container_cpu_throttled_rate.csv",
     'rate(container_cpu_cfs_throttled_periods_total{namespace="open5gs",container!=""}[2m]) '
     '/ rate(container_cpu_cfs_periods_total{namespace="open5gs",container!=""}[2m])'),
    ("pod_restarts.csv",
     'kube_pod_container_status_restarts_total{namespace="open5gs"}'),
    ("monitoring_cpu_usage_rate.csv",
     'rate(container_cpu_usage_seconds_total{namespace="monitoring",container!=""}[2m])'),
    ("monitoring_memory_working_set.csv",
     'container_memory_working_set_bytes{namespace="monitoring",container!=""}'),
    ("node_cpu_usage.csv",
     'rate(node_cpu_seconds_total{mode!="idle"}[2m])'),
    ("node_memory_available.csv",
     'node_memory_MemAvailable_bytes'),
    # --- Pod health (kube-state-metrics) ---
    ("pod_ready.csv",
     'kube_pod_status_ready{namespace="open5gs",condition="true"}'),
    ("pod_running.csv",
     'kube_pod_status_phase{namespace="open5gs",phase="Running"}'),
    # --- Network I/O ---
    ("network_rx_bytes_rate.csv",
     'rate(container_network_receive_bytes_total{namespace="open5gs"}[2m])'),
    ("network_tx_bytes_rate.csv",
     'rate(container_network_transmit_bytes_total{namespace="open5gs"}[2m])'),
    # --- Beyla eBPF application metrics (compare against Prometheus infra layer) ---
    ("beyla_http_server_duration.csv",
     'rate(http_server_request_duration_seconds_sum{k8s_namespace_name="open5gs"}[2m])'
     ' / rate(http_server_request_duration_seconds_count{k8s_namespace_name="open5gs"}[2m])'),
    ("beyla_http_client_duration.csv",
     'rate(http_client_request_duration_seconds_sum{k8s_namespace_name="open5gs"}[2m])'
     ' / rate(http_client_request_duration_seconds_count{k8s_namespace_name="open5gs"}[2m])'),
    ("beyla_http_server_request_rate.csv",
     'rate(http_server_request_duration_seconds_count{k8s_namespace_name="open5gs"}[2m])'),
    ("beyla_http_server_error_rate.csv",
     'rate(http_server_request_duration_seconds_count{k8s_namespace_name="open5gs",http_response_status_code=~"5.."}[2m])'),
    ("beyla_http_client_request_rate.csv",
     'rate(http_client_request_duration_seconds_count{k8s_namespace_name="open5gs"}[2m])'),
    ("beyla_http_client_error_rate.csv",
     'rate(http_client_request_duration_seconds_count{k8s_namespace_name="open5gs",http_response_status_code=~"5.."}[2m])'),
    # --- Beyla eBPF latency percentiles (histogram_quantile, per NF pod) ---
    # These are the canonical "call time" metrics — proper percentiles from
    # bucket data rather than mean-only sum/count ratios. Grouped by
    # k8s_pod_name so each row identifies which NF is being measured.
    # Server-side (NF receiving the SBI call):
    ("beyla_http_server_p50.csv",
     'histogram_quantile(0.50, sum by (le, k8s_pod_name)'
     '(rate(http_server_request_duration_seconds_bucket{k8s_namespace_name="open5gs"}[2m])))'),
    ("beyla_http_server_p95.csv",
     'histogram_quantile(0.95, sum by (le, k8s_pod_name)'
     '(rate(http_server_request_duration_seconds_bucket{k8s_namespace_name="open5gs"}[2m])))'),
    ("beyla_http_server_p99.csv",
     'histogram_quantile(0.99, sum by (le, k8s_pod_name)'
     '(rate(http_server_request_duration_seconds_bucket{k8s_namespace_name="open5gs"}[2m])))'),
    # Client-side (NF making the outbound SBI call):
    ("beyla_http_client_p50.csv",
     'histogram_quantile(0.50, sum by (le, k8s_pod_name)'
     '(rate(http_client_request_duration_seconds_bucket{k8s_namespace_name="open5gs"}[2m])))'),
    ("beyla_http_client_p95.csv",
     'histogram_quantile(0.95, sum by (le, k8s_pod_name)'
     '(rate(http_client_request_duration_seconds_bucket{k8s_namespace_name="open5gs"}[2m])))'),
    ("beyla_http_client_p99.csv",
     'histogram_quantile(0.99, sum by (le, k8s_pod_name)'
     '(rate(http_client_request_duration_seconds_bucket{k8s_namespace_name="open5gs"}[2m])))'),
    ("beyla_cpu_usage_rate.csv",
     'rate(container_cpu_usage_seconds_total{namespace="open5gs",pod=~"beyla.*",container!="",node=~"open5gs-worker.*"}[2m])'),
    ("beyla_memory_working_set.csv",
     'container_memory_working_set_bytes{namespace="open5gs",pod=~"beyla.*",container!="",node=~"open5gs-worker.*"}'),
    # --- Open5GS native application metrics ---
    # AMF: registration and authentication counters
    ("open5gs_amf_registered_subscribers.csv",
     'fivegs_amffunction_rm_registeredsubnbr'),
    ("open5gs_amf_reg_init_req.csv",
     'rate(fivegs_amffunction_rm_reginitreq[2m])'),
    ("open5gs_amf_reg_init_succ.csv",
     'rate(fivegs_amffunction_rm_reginitsucc[2m])'),
    ("open5gs_amf_auth_fail.csv",
     'rate(fivegs_amffunction_amf_authfail[2m])'),
    ("open5gs_amf_auth_reject.csv",
     'rate(fivegs_amffunction_amf_authreject[2m])'),
    ("open5gs_amf_paging_req.csv",
     'rate(fivegs_amffunction_mm_paging5greq[2m])'),
    ("open5gs_amf_sessions.csv",
     'amf_session'),
    # SMF: PDU session and PFCP (N4) metrics
    ("open5gs_smf_session_nbr.csv",
     'fivegs_smffunction_sm_sessionnbr'),
    ("open5gs_smf_pdu_session_req.csv",
     'rate(fivegs_smffunction_sm_pdusessioncreationreq[2m])'),
    ("open5gs_smf_pdu_session_succ.csv",
     'rate(fivegs_smffunction_sm_pdusessioncreationsucc[2m])'),
    ("open5gs_smf_n4_session_estab.csv",
     'rate(fivegs_smffunction_sm_n4sessionestabreq[2m])'),
    # UPF: PFCP sessions and GTP data plane
    ("open5gs_upf_session_nbr.csv",
     'fivegs_upffunction_upf_sessionnbr'),
    ("open5gs_upf_n4_session_estab.csv",
     'rate(fivegs_upffunction_sm_n4sessionestabreq[2m])'),
    ("open5gs_pfcp_sessions_active.csv",
     'pfcp_sessions_active'),
    ("open5gs_pfcp_peers_active.csv",
     'pfcp_peers_active'),
    # NOTE: Open5GS 2.7.5 does not export N3 GTP-U data-packet counters
    # (fivegs_ep_n3_gtp_*datapktn3upf are absent / flat zero). Use the
    # already-collected UPF container network_rx/tx_bytes_rate as the
    # data-plane traffic signal instead.
    # SMF: N4 session report success rate (gap = PFCP health)
    ("open5gs_smf_n4_session_report.csv",
     'rate(fivegs_smffunction_sm_n4sessionreport[2m])'),
    ("open5gs_smf_n4_session_report_succ.csv",
     'rate(fivegs_smffunction_sm_n4sessionreportsucc[2m])'),
    # AMF: gNB count and RAN UE count (drop = N2 interface fault)
    ("open5gs_amf_gnb_count.csv",
     'gnb'),
    ("open5gs_amf_ran_ue_count.csv",
     'ran_ue'),
    # UPF: QoS flow count (complement to session count)
    ("open5gs_upf_qos_flows.csv",
     'fivegs_upffunction_upf_qosflows'),
    # GTP: node failure counter
    ("open5gs_gtp_node_failed.csv",
     'rate(gtp_new_node_failed[2m])'),

    # ---- Failure counters (primary fault-distinguishing signals) ----
    # Zero-suppressed until first failure: empty CSV in pre, populates
    # during/after a fault — exactly the discriminating behaviour wanted.
    ("open5gs_smf_pdu_session_fail.csv",
     'rate(fivegs_smffunction_sm_pdusessioncreationfail[2m])'),
    ("open5gs_smf_n4_session_estab_fail.csv",
     'rate(fivegs_smffunction_sm_n4sessionestabfail[2m])'),
    ("open5gs_upf_n4_session_estab_fail.csv",
     'rate(fivegs_upffunction_sm_n4sessionestabfail[2m])'),
    ("open5gs_amf_reg_init_fail.csv",
     'rate(fivegs_amffunction_rm_reginitfail[2m])'),
    ("open5gs_amf_reg_mob_fail.csv",
     'rate(fivegs_amffunction_rm_regmobfail[2m])'),
    ("open5gs_amf_reg_period_fail.csv",
     'rate(fivegs_amffunction_rm_regperiodfail[2m])'),
    ("open5gs_amf_reg_emerg_fail.csv",
     'rate(fivegs_amffunction_rm_regemergfail[2m])'),

    # ---- Clean session gauges (SMF-side; not affected by the UPF
    # upf_sessionnbr/qosflows over-count bug) ----
    ("open5gs_smf_ues_active.csv",
     'ues_active'),
    ("open5gs_smf_bearers_active.csv",
     'bearers_active'),
    ("open5gs_smf_qos_flow_nbr.csv",
     'fivegs_smffunction_sm_qos_flow_nbr'),
]


def query_range(url: str, query: str, start: int, end: int, step: str) -> list:
    params = urllib.parse.urlencode({
        "query": query,
        "start": start,
        "end": end,
        "step": step,
    })
    req_url = f"{url}/api/v1/query_range?{params}"
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req_url, timeout=30) as resp:
                data = json.load(resp)
            if data.get("status") != "success":
                print(f"  [WARN] Prometheus query failed: {data.get('error', 'unknown')}", file=sys.stderr)
                return []
            return data["data"]["result"]
        except Exception as e:
            if attempt == 2:
                print(f"  [WARN] Query error after 3 attempts: {e}", file=sys.stderr)
                return []
            time.sleep(2)
    return []


def results_to_csv(results: list, out_path: Path):
    if not results:
        # Write a header-only stub so missing data is distinguishable from
        # collector failure (empty file) vs metric genuinely absent.
        with open(out_path, "w", newline="") as f:
            f.write("timestamp,value\n")
        print(f"  [prom] {out_path.name}: 0 rows (empty stub written)", file=sys.stderr)
        return
    rows = []
    for series in results:
        labels = series["metric"]
        for ts, val in series["values"]:
            row = {"timestamp": ts, "value": val}
            row.update(labels)
            rows.append(row)
    if not rows:
        return
    fieldnames = list(rows[0].keys())
    with open(out_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    print(f"  [prom] {out_path.name}: {len(rows)} rows")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:9090")
    parser.add_argument("--start", type=int, required=True)
    parser.add_argument("--end", type=int, required=True)
    parser.add_argument("--step", default="5s")
    parser.add_argument("--out", required=True)
    parser.add_argument("--extra-metrics", nargs="*", default=[],
                        help="label:query:filename triples")
    args = parser.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    metrics = list(STANDARD_METRICS)
    for extra in args.extra_metrics:
        parts = extra.split(":", 2)
        if len(parts) == 3:
            _, query, fname = parts
            metrics.append((fname, query))

    for fname, query in metrics:
        results = query_range(args.url, query, args.start, args.end, args.step)
        results_to_csv(results, out_dir / fname)


if __name__ == "__main__":
    main()

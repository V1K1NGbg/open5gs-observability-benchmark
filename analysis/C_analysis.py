#!/usr/bin/env python3
# pyright: basic
"""
analysis/C_analysis.py

Fault detection analysis for Experiment C — 22 injected faults in a live 5G core.

For each fault × method pair, computes a normalised z-score signal strength by
comparing the *during* phase against the stable *pre* phase baseline.  Binary
detection is declared when |z| > Z_THRESHOLD (= 3.0).

Detection methods:
  Prometheus  — highest z-score across all NF-layer Prometheus metrics
  Beyla       — highest z-score across Beyla HTTP span metrics
  Loki        — z-score on total error-log line rate (errors + ue_failures)
  RTT         — z-score on mean UE data-plane ping RTT

Results are averaged across runs (run_1 … run_N) for robustness.

Outputs:
  analysis/C_figures/fig_detection_matrix.png   — heatmap, signal strength 0-1
  analysis/C_results.json                       — machine-readable per-fault data

Usage:
    python3 analysis/C_analysis.py
    python3 analysis/C_analysis.py --data-dir /path/to/data/experiments/C
    python3 analysis/C_analysis.py --out-dir /path/to/output
    python3 analysis/C_analysis.py --no-plots
    python3 analysis/C_analysis.py --clean      # minimal figures for publication
"""

from __future__ import annotations

import argparse
import json
import sys
import warnings
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd
from scipy import stats as scipy_stats

import plot_style as ps

warnings.filterwarnings("ignore", category=FutureWarning)

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.colors as mcolors
    import matplotlib.patches as mpatches
    from matplotlib.patches import FancyBboxPatch
    HAS_MATPLOTLIB = True
except ImportError:
    HAS_MATPLOTLIB = False
    print("[WARN] matplotlib not available — skipping plot generation", file=sys.stderr)

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
REPO_ROOT = Path(__file__).resolve().parent.parent
DATA_ROOT = REPO_ROOT / "data" / "experiments" / "C"
OUT_DIR   = Path(__file__).resolve().parent / "C_figures"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
Z_THRESHOLD  = 3.0   # z-score above which a fault is considered detected
LOKI_Z_THRESH = 10.0 # stricter threshold for Loki: raw error counts are noisy
                     # (every fault changes log volume); only large anomalies count
EPSILON_ABS  = 1e-6  # absolute std floor to prevent division by near-zero

# Fault catalogue: dir_name → (short_label, fault_class)
FAULTS: list[tuple[str, str, str]] = [
    ("01-cpu-stress-amf",                       "CPU stress – AMF",               "Resource"),
    ("02-memory-pressure-upf",                  "Memory pressure – UPF",          "Resource"),
    ("03-pod-crash-amf",                        "Pod crash – AMF",                "Crash"),
    ("04-network-delay-gnb-amf",                "Network delay – gNB/AMF",        "Delay"),
    ("05-network-partition-amf-scp",            "Network partition – AMF/SCP",    "Partition"),
    ("06-packet-loss-upf",                      "Packet loss – UPF",              "Partition"),
    ("07-pod-crash-smf",                        "Pod crash – SMF",                "Crash"),
    ("08-cpu-stress-scp",                       "CPU stress – SCP",               "Resource"),
    ("09-network-delay-nrf",                    "Network delay – NRF",            "Delay"),
    ("10-pfcp-session-establishment-flood-upf", "PFCP session flood – UPF",       "Protocol"),
    ("11-pfcp-session-deletion-upf",            "PFCP session deletion – UPF",    "Protocol"),
    ("12-pfcp-session-modification-drop-upf",   "PFCP mod. drop – UPF",           "Protocol"),
    ("13-pfcp-session-modification-dupl-upf",   "PFCP mod. duplicate – UPF",      "Protocol"),
    ("14-upf-infrastructure-packet-loss",       "Infra packet loss – UPF",        "Partition"),
    ("15-nrf-cascade",                          "NRF cascade failure",            "Protocol"),
    ("16-cpu-stress-ausf",                      "CPU stress – AUSF",              "Resource"),
    ("17-network-delay-scp",                    "Network delay – SCP",            "Delay"),
    ("18-cpu-stress-nrf",                       "CPU stress – NRF",               "Resource"),
    ("19-udm-pod-crash",                        "Pod crash – UDM",                "Crash"),
    ("20-mongodb-pod-kill",                     "MongoDB pod kill",               "Protocol"),
    ("21-n2-partition-amf-gnb",                 "N2 partition – AMF/gNB",         "Partition"),
    ("22-memory-pressure-amf",                  "Memory pressure – AMF",          "Resource"),
]

CLASS_COLOURS = {
    "Resource":  "#d62728",
    "Crash":     "#e15759",
    "Delay":     "#ff7f0e",
    "Partition": "#9467bd",
    "Protocol":  "#1f77b4",
}

# ---------------------------------------------------------------------------
# Low-level CSV helpers
# ---------------------------------------------------------------------------

def _load_csv(path: Path) -> pd.DataFrame:
    if not path.exists():
        return pd.DataFrame()
    try:
        return pd.read_csv(path)
    except Exception:
        return pd.DataFrame()


def _timeseries(df: pd.DataFrame, value_col: str = "value", agg: str = "sum") -> np.ndarray:
    """Return per-timestep aggregate (sum or mean) as a 1-D array."""
    if df.empty or value_col not in df.columns:
        return np.array([])
    s = pd.to_numeric(df[value_col], errors="coerce")
    if "timestamp" in df.columns:
        grp = s.groupby(df["timestamp"])
        ts = grp.sum() if agg == "sum" else grp.mean()
    else:
        ts = s.dropna()
    return ts.dropna().to_numpy(dtype=float)


def _z_score(pre: np.ndarray, during: np.ndarray) -> float:
    """
    Robust |z| = |mean(during) - mean(pre)| / effective_std.

    effective_std = max(std(pre), 2% of |mean_pre|, EPSILON_ABS)
    This prevents exploding z-scores when the baseline is near-constant.
    The 2% floor means a change must be >6% of the signal magnitude to
    cross the Z_THRESHOLD=3 boundary, which is conservative.
    """
    if len(pre) < 2 or len(during) < 1:
        return 0.0
    pre_f   = pre[np.isfinite(pre)]
    dur_f   = during[np.isfinite(during)]
    if len(pre_f) < 2 or len(dur_f) < 1:
        return 0.0
    mu_pre  = float(np.mean(pre_f))
    sig_pre = float(np.std(pre_f, ddof=1))
    mu_dur  = float(np.mean(dur_f))
    eff_std = max(sig_pre, abs(mu_pre) * 0.02, EPSILON_ABS)
    return abs(mu_dur - mu_pre) / eff_std


def _norm_z(z: float) -> float:
    """
    Log-scale normalised z-score mapped to [0, 1].

    Using log10(1 + z) / 2 so that:
      z =   0 → 0.0
      z =   3 → 0.30  (detection threshold)
      z =  10 → 0.52
      z = 100 → 1.0   (saturates)

    Log scaling gives better visual differentiation when z-scores span
    several orders of magnitude.
    """
    import math
    return float(min(math.log10(1.0 + abs(z)) / 2.0, 1.0))


# ---------------------------------------------------------------------------
# Per-method signal computation
# ---------------------------------------------------------------------------

def _prom_signal(fault_dir: Path) -> float:
    """
    Prometheus signal = max |z|-score across all NF-layer metrics.
    Includes: container CPU/memory, pod restarts, network I/O, all open5gs_* counters.
    Beyla and monitoring-namespace pods are excluded.
    """
    prom_pre    = fault_dir / "prometheus" / "pre"
    prom_during = fault_dir / "prometheus" / "during"
    if not prom_pre.exists() or not prom_during.exists():
        return 0.0

    best_z = 0.0

    # ── Container CPU (NF containers only) ────────────────────────────────
    for csv_name in ("container_cpu_usage_rate.csv",):
        df_pre = _load_csv(prom_pre / csv_name)
        df_dur = _load_csv(prom_during / csv_name)
        for df in (df_pre, df_dur):
            if not df.empty and "container" in df.columns:
                df.drop(df[df["container"].isin(["beyla", "POD", ""])].index, inplace=True)
        pre_ts  = _timeseries(df_pre, agg="sum")
        dur_ts  = _timeseries(df_dur, agg="sum")
        best_z  = max(best_z, _z_score(pre_ts, dur_ts))

    # ── Container memory (NF containers only) ──────────────────────────────
    for csv_name in ("container_memory_working_set_bytes.csv",):
        df_pre = _load_csv(prom_pre / csv_name)
        df_dur = _load_csv(prom_during / csv_name)
        for df in (df_pre, df_dur):
            if not df.empty and "container" in df.columns:
                df.drop(df[df["container"].isin(["beyla", "POD", ""])].index, inplace=True)
        pre_ts  = _timeseries(df_pre, agg="sum")
        dur_ts  = _timeseries(df_dur, agg="sum")
        best_z  = max(best_z, _z_score(pre_ts, dur_ts))

    # ── Pod restarts and pod ready ─────────────────────────────────────────
    for csv_name in ("pod_restarts.csv", "pod_running.csv", "pod_ready.csv"):
        pre_ts  = _timeseries(_load_csv(prom_pre / csv_name), agg="sum")
        dur_ts  = _timeseries(_load_csv(prom_during / csv_name), agg="sum")
        best_z  = max(best_z, _z_score(pre_ts, dur_ts))

    # ── Network I/O ────────────────────────────────────────────────────────
    for csv_name in ("network_rx_bytes_rate.csv", "network_tx_bytes_rate.csv"):
        pre_ts  = _timeseries(_load_csv(prom_pre / csv_name), agg="sum")
        dur_ts  = _timeseries(_load_csv(prom_during / csv_name), agg="sum")
        best_z  = max(best_z, _z_score(pre_ts, dur_ts))

    # ── All open5gs application metrics ────────────────────────────────────
    for csv_path in sorted(prom_during.glob("open5gs_*.csv")):
        csv_name  = csv_path.name
        pre_ts    = _timeseries(_load_csv(prom_pre / csv_name), agg="sum")
        dur_ts    = _timeseries(_load_csv(prom_during / csv_name), agg="sum")
        best_z    = max(best_z, _z_score(pre_ts, dur_ts))

    return best_z


def _beyla_signal(fault_dir: Path) -> float:
    """
    Beyla signal = max |z|-score across HTTP span metrics, evaluated per-NF service.

    Computing the z-score at the per-service level (instead of aggregating across
    all services) correctly captures a fault that stresses a single NF while the
    aggregate signal would be diluted by unaffected NFs.

    Services with fewer than 30 pre-phase data points are skipped because z-score
    estimation is unreliable for low-traffic NFs (e.g. AUSF at 50 UEs).
    """
    prom_pre    = fault_dir / "prometheus" / "pre"
    prom_during = fault_dir / "prometheus" / "during"
    if not prom_pre.exists() or not prom_during.exists():
        return 0.0

    MIN_PRE_POINTS = 30  # minimum samples needed for reliable z-score estimation
    best_z = 0.0

    for csv_name in (
        "beyla_http_server_duration.csv",
        "beyla_http_server_error_rate.csv",
        "beyla_http_server_request_rate.csv",
        "beyla_http_client_duration.csv",
        "beyla_http_client_error_rate.csv",
        "beyla_http_client_request_rate.csv",
    ):
        df_pre = _load_csv(prom_pre / csv_name)
        df_dur = _load_csv(prom_during / csv_name)
        if df_pre.empty or df_dur.empty:
            continue

        # Identify the service/instance grouping column
        svc_col = next(
            (c for c in ("exported_instance", "exported_job", "container") if c in df_pre.columns),
            None,
        )

        if svc_col is None:
            # No per-service breakdown: use aggregate signal
            agg_mode = "mean" if "duration" in csv_name else "sum"
            pre_ts = _timeseries(df_pre, agg=agg_mode)
            dur_ts = _timeseries(df_dur, agg=agg_mode)
            best_z = max(best_z, _z_score(pre_ts, dur_ts))
            continue

        # Per-service z-score
        for svc in df_pre[svc_col].dropna().unique():
            df_pre_s = df_pre[df_pre[svc_col] == svc]
            df_dur_s = df_dur[df_dur[svc_col] == svc]
            if len(df_pre_s) < MIN_PRE_POINTS:
                continue  # skip low-traffic NFs — signal unreliable
            agg_mode = "mean" if "duration" in csv_name else "sum"
            pre_ts = _timeseries(df_pre_s, agg=agg_mode)
            dur_ts = _timeseries(df_dur_s, agg=agg_mode)
            best_z = max(best_z, _z_score(pre_ts, dur_ts))

    return best_z


def _loki_signal(fault_dir: Path) -> float:
    """
    Loki signal = z-score on error-log line rate.
    Uses errors.csv + ue_failures.csv; compares line counts per 5-min window.
    """
    loki_pre    = fault_dir / "loki" / "pre"
    loki_during = fault_dir / "loki" / "during"
    if not loki_pre.exists() or not loki_during.exists():
        return 0.0

    def _count_lines(directory: Path) -> int:
        total = 0
        for csv_name in ("errors.csv", "ue_failures.csv"):
            df = _load_csv(directory / csv_name)
            if not df.empty:
                total += max(len(df) - 0, 0)  # read_csv already strips header
        return total

    # We compare rate (lines per window) across both periods.
    # For a single-window comparison use a one-sample Poisson approximation:
    # z = |count_during - count_pre| / (sqrt(count_pre) + ε)
    n_pre   = _count_lines(loki_pre)
    n_dur   = _count_lines(loki_during)
    z = abs(n_dur - n_pre) / (max(n_pre ** 0.5, 1.0))
    return float(z)


def _parse_rtt_df(path: Path) -> tuple[np.ndarray, float]:
    """Return (rtt_values_ms, packet_loss_fraction) from a ue_rtt.csv file."""
    df = _load_csv(path)
    if df.empty:
        return np.array([]), float("nan")
    rtt_col = "rtt_ms" if "rtt_ms" in df.columns else ("value" if "value" in df.columns else None)
    total_rows = len(df)
    if rtt_col:
        rtt_vals = pd.to_numeric(df[rtt_col], errors="coerce")
        good = rtt_vals.dropna().to_numpy(dtype=float)
    else:
        good = np.array([])
    loss_frac = float("nan")
    if "status" in df.columns:
        n_ok   = int((df["status"] == "ok").sum())
        n_loss = int((df["status"] == "loss").sum())
        total  = n_ok + n_loss
        loss_frac = n_loss / total if total > 0 else 0.0
    elif total_rows > 0:
        loss_frac = 1.0 - len(good) / total_rows
    return good, loss_frac


def _rtt_signal(fault_dir: Path) -> float:
    """
    RTT signal = max of:
      • |z| on mean UE data-plane ping RTT (ms)
      • |z| on packet-loss rate (fraction of probes lost)
    """
    pre_rtt,  pre_loss  = _parse_rtt_df(fault_dir / "rtt" / "pre" / "ue_rtt.csv")
    dur_rtt,  dur_loss  = _parse_rtt_df(fault_dir / "rtt" / "during" / "ue_rtt.csv")

    z_latency = _z_score(pre_rtt, dur_rtt)

    z_loss = 0.0
    if not (np.isnan(pre_loss) or np.isnan(dur_loss)):
        change = abs(dur_loss - pre_loss)
        sd_pre = max((pre_loss * (1 - pre_loss)) ** 0.5, 0.01)
        z_loss = change / (sd_pre + EPSILON_ABS)

    return max(z_latency, z_loss)


# ---------------------------------------------------------------------------
# Per-fault analysis (single run)
# ---------------------------------------------------------------------------

def analyse_fault(fault_dir: Path) -> dict[str, Any]:
    """Return signal strengths, detection flags, and RTT pre/during stats."""
    prom_z  = _prom_signal(fault_dir)
    beyla_z = _beyla_signal(fault_dir)
    loki_z  = _loki_signal(fault_dir)
    rtt_z   = _rtt_signal(fault_dir)

    pre_rtt, pre_loss  = _parse_rtt_df(fault_dir / "rtt" / "pre" / "ue_rtt.csv")
    dur_rtt, dur_loss  = _parse_rtt_df(fault_dir / "rtt" / "during" / "ue_rtt.csv")
    rtt_pre_mean  = float(np.mean(pre_rtt[np.isfinite(pre_rtt)])) if len(pre_rtt) > 0 else float("nan")
    rtt_dur_mean  = float(np.mean(dur_rtt[np.isfinite(dur_rtt)])) if len(dur_rtt) > 0 else float("nan")
    rtt_pre_loss  = float(pre_loss) if not np.isnan(pre_loss) else 0.0
    rtt_dur_loss  = float(dur_loss) if not np.isnan(dur_loss) else 0.0

    return {
        "prom_z":          prom_z,
        "beyla_z":         beyla_z,
        "loki_z":          loki_z,
        "rtt_z":           rtt_z,
        "prom_detected":   prom_z  >= Z_THRESHOLD,
        "beyla_detected":  beyla_z >= Z_THRESHOLD,
        "loki_detected":   loki_z  >= LOKI_Z_THRESH,
        "rtt_detected":    rtt_z   >= Z_THRESHOLD,
        "rtt_pre_mean_ms": rtt_pre_mean,
        "rtt_dur_mean_ms": rtt_dur_mean,
        "rtt_pre_loss":    rtt_pre_loss,
        "rtt_dur_loss":    rtt_dur_loss,
    }


# ---------------------------------------------------------------------------
# Load all runs for all faults
# ---------------------------------------------------------------------------

def load_all(data_root: Path) -> dict[str, dict[str, Any]]:
    """
    Returns a dict keyed by fault dirname.
    Each value has 'mean' and 'runs' sub-keys with aggregated/raw data.
    """
    run_dirs = sorted([d for d in data_root.iterdir() if d.is_dir() and d.name.startswith("run_")])
    if not run_dirs:
        print(f"[WARN] No run_* directories found under {data_root}", file=sys.stderr)
        return {}

    results: dict[str, dict[str, Any]] = {}

    for fault_dir_name, label, fault_class in FAULTS:
        per_run: list[dict[str, Any]] = []
        for run_dir in run_dirs:
            fault_path = run_dir / fault_dir_name
            if not fault_path.exists():
                continue
            per_run.append(analyse_fault(fault_path))

        if not per_run:
            print(f"  [WARN] No data found for {fault_dir_name}", file=sys.stderr)
            per_run = [{
                "prom_z": 0.0, "beyla_z": 0.0, "loki_z": 0.0, "rtt_z": 0.0,
                "prom_detected": False, "beyla_detected": False,
                "loki_detected": False, "rtt_detected": False,
            }]

        # For z-score magnitude use the MEDIAN across runs (robust to outliers).
        # For detection:
        #   - OR (any run): max capability — answers "can it ever detect this?"
        #   - detect_frac: fraction of runs detecting — answers "how reliably?"
        # A fault detected in only 1/3 runs with median z < threshold is likely
        # a borderline/unreliable detection (possible noise at the threshold).
        avg: dict[str, Any] = {}
        for key in ("prom_z", "beyla_z", "loki_z", "rtt_z",
                    "rtt_pre_mean_ms", "rtt_dur_mean_ms",
                    "rtt_pre_loss", "rtt_dur_loss"):
            vals = [r[key] for r in per_run
                    if r.get(key) is not None and np.isfinite(r.get(key, float("nan")))]
            avg[key] = float(np.median(vals)) if vals else 0.0
        for key in ("prom_detected", "beyla_detected", "loki_detected", "rtt_detected"):
            votes = [r[key] for r in per_run]
            n_runs = len(votes)
            n_det  = sum(1 for v in votes if v)
            avg[key] = any(votes)                              # OR logic (max capability)
            avg[key.replace("_detected", "_detect_frac")] = (  # reliability fraction
                n_det / n_runs if n_runs > 0 else 0.0
            )
            avg[key.replace("_detected", "_detect_n")]    = n_det
            avg[key.replace("_detected", "_run_n")]        = n_runs

        results[fault_dir_name] = {
            "label":       label,
            "fault_class": fault_class,
            "mean":        avg,
            "runs":        per_run,
        }

    return results


# ---------------------------------------------------------------------------
# Figure styling helpers
# ---------------------------------------------------------------------------

PROM_COLOUR  = "#4e79a7"
BEYLA_COLOUR = "#f28e2b"


def _scatter_detection_marker(
    ax,
    sig: float,
    y: float,
    frac: float,
    *,
    marker: str,
    colour: str,
) -> None:
    """Draw filled, hollow, or missed marker based on run-level detection fraction."""
    if frac >= 1.0:
        ax.scatter(sig, y, s=100, color=colour, marker=marker,
                   edgecolors="black", linewidths=0.7, zorder=5)
    elif frac > 0.0:
        ax.scatter(sig, y, s=110, facecolors="none", marker=marker,
                   edgecolors=colour, linewidths=2.2, zorder=5)
    else:
        ax.scatter(sig, y, s=70, color="#cccccc", marker="x",
                   linewidths=1.5, zorder=5)


def _detection_legend_items(rows: list[dict]) -> list:
    """Legend entries only for marker styles that appear in the data."""
    from matplotlib.lines import Line2D

    prom_full  = any(r["prom_frac"] >= 1.0 for r in rows)
    prom_part  = any(0 < r["prom_frac"] < 1.0 for r in rows)
    prom_miss  = any(r["prom_frac"] <= 0.0 for r in rows)
    beyla_full = any(r["bey_frac"] >= 1.0 for r in rows)
    beyla_part = any(0 < r["bey_frac"] < 1.0 for r in rows)
    beyla_miss = any(r["bey_frac"] <= 0.0 for r in rows)

    short = ps.is_clean()
    items: list = []
    if prom_full:
        items.append(Line2D([0], [0], marker="o", color="w", markerfacecolor=PROM_COLOUR,
                            markersize=9, markeredgecolor="black",
                            label="Prometheus" if short else "Prometheus — reliable (all runs)"))
    if prom_part:
        items.append(Line2D([0], [0], marker="o", color="w", markerfacecolor="none",
                            markersize=9, markeredgecolor=PROM_COLOUR, markeredgewidth=2.2,
                            label="Prometheus (partial)" if short
                            else "Prometheus — borderline (some runs)"))
    if beyla_full:
        items.append(Line2D([0], [0], marker="s", color="w", markerfacecolor=BEYLA_COLOUR,
                            markersize=9, markeredgecolor="black",
                            label="Beyla eBPF" if short else "Beyla eBPF — reliable"))
    if beyla_part:
        items.append(Line2D([0], [0], marker="s", color="w", markerfacecolor="none",
                            markersize=9, markeredgecolor=BEYLA_COLOUR, markeredgewidth=2.2,
                            label="Beyla eBPF (partial)" if short
                            else "Beyla eBPF — borderline"))
    if prom_miss or beyla_miss:
        items.append(Line2D([0], [0], marker="x", color="#aaaaaa", markersize=9,
                            linewidth=0, label="Not detected"))
    items.append(Line2D([0], [0], linestyle="--", color="#888888",
                        label=f"Threshold (z={Z_THRESHOLD})" if short
                        else f"Detection threshold (z={Z_THRESHOLD})"))
    return items


def _categorise_detection_outcome(pf: float, bf: float) -> str:
    if pf >= 1.0 and bf >= 1.0:
        return "Both reliable"
    if pf >= 1.0 and bf < 1.0:
        return "Prom only"
    if bf >= 1.0 and pf < 1.0:
        return "Beyla only"
    if pf > 0.0 or bf > 0.0:
        return "Borderline"
    return "Neither"


# ---------------------------------------------------------------------------
# Figure 1: Detection matrix heatmap
# ---------------------------------------------------------------------------

def fig_detection_matrix(fault_data: dict[str, dict], out_dir: Path) -> None:
    """
    Dumbbell (Cleveland dot) chart — signal strength per fault per method.

    Each row = one fault, grouped and sorted by fault class.
    Two markers per row:
      ● circle  = Prometheus signal
      ■ square  = Beyla eBPF signal
    A thin horizontal connector shows the gap between the two methods.

    Marker style encodes detection reliability across runs:
      filled solid  = detected in ALL runs  (reliable)
      filled hollow = detected in SOME runs (borderline)
      ×             = not detected in any run

    Row background is tinted by fault class for easy grouping.
    Vertical dashed line marks the detection threshold (z = 3).
    """
    if not HAS_MATPLOTLIB:
        return

    THRESH = _norm_z(Z_THRESHOLD)

    fault_order = [f[0] for f in FAULTS]

    # Build per-fault data rows, grouped by class
    class_order = ["Resource", "Crash", "Delay", "Partition", "Protocol"]
    rows = []
    for fname, label, fault_class in FAULTS:
        if fname not in fault_data:
            continue
        avg = fault_data[fname]["mean"]
        rows.append({
            "label":       label,
            "short":       fname[:2],
            "fault_class": fault_class,
            "prom_sig":    _norm_z(avg.get("prom_z",  0.0)),
            "bey_sig":     _norm_z(avg.get("beyla_z", 0.0)),
            "prom_frac":   avg.get("prom_detect_frac",  0.0),
            "bey_frac":    avg.get("beyla_detect_frac", 0.0),
            "prom_n":      int(avg.get("prom_detect_n", 0)),
            "bey_n":       int(avg.get("beyla_detect_n", 0)),
            "run_n":       int(avg.get("prom_run_n", 3)),
        })
    # Sort: class order first, then by avg signal within class (descending)
    cls_rank = {c: i for i, c in enumerate(class_order)}
    rows.sort(key=lambda r: (cls_rank.get(r["fault_class"], 99),
                             -(r["prom_sig"] + r["bey_sig"]) / 2))

    n = len(rows)
    fig, ax = plt.subplots(figsize=(13, max(8, n * 0.42 + 2)))
    ps.suptitle(
        fig,
        "Detection Signal Strength per Fault — Prometheus vs Beyla eBPF\n"
        "Each row = one fault  │  ● Prometheus  ■ Beyla eBPF  │"
        "  Filled = all runs detected  Outline = borderline  × = never",
        clean="Fault detection: Prometheus vs Beyla",
        fontsize=11, fontweight="bold",
    )

    y = np.arange(n)

    # ── Row backgrounds by fault class ───────────────────────────────────
    class_boundaries = []
    prev_cls = None
    shade_toggle = False
    for i, row in enumerate(rows):
        if row["fault_class"] != prev_cls:
            shade_toggle = not shade_toggle
            if prev_cls is not None:
                class_boundaries.append(i - 0.5)
            prev_cls = row["fault_class"]
        bg = CLASS_COLOURS.get(row["fault_class"], "#aaaaaa")
        ax.axhspan(i - 0.45, i + 0.45, xmin=0, xmax=1,
                   color=bg, alpha=0.07, zorder=0)

    # ── Dumbbell connectors ───────────────────────────────────────────────
    for i, row in enumerate(rows):
        lo, hi = sorted([row["prom_sig"], row["bey_sig"]])
        ax.plot([lo, hi], [i, i], color="#cccccc", linewidth=1.5, zorder=1)

    # ── Prometheus dots (circles) ─────────────────────────────────────────
    for i, row in enumerate(rows):
        _scatter_detection_marker(
            ax, row["prom_sig"], i, row["prom_frac"],
            marker="o", colour=PROM_COLOUR,
        )
        ps.label(ax, row["prom_sig"] + 0.012, i + 0.22,
                 f"{row['prom_n']}/{row['run_n']}",
                 fontsize=6.5, color="#555555", va="center", ha="left")

    # ── Beyla dots (squares) ──────────────────────────────────────────────
    for i, row in enumerate(rows):
        _scatter_detection_marker(
            ax, row["bey_sig"], i, row["bey_frac"],
            marker="s", colour=BEYLA_COLOUR,
        )
        ps.label(ax, row["bey_sig"] - 0.012, i - 0.22,
                 f"{row['bey_n']}/{row['run_n']}",
                 fontsize=6.5, color="#555555", va="center", ha="right")

    # ── Fault labels on y-axis ────────────────────────────────────────────
    ax.set_yticks(y)
    ylabels = [f"[{r['short']}] {r['label']}" for r in rows]
    ax.set_yticklabels(ylabels, fontsize=8)

    # Class group separators
    for b in class_boundaries:
        ax.axhline(b, color="#aaaaaa", linewidth=0.8, linestyle="--", alpha=0.6)

    # Class name annotations on the right
    prev_cls, grp_start = None, 0
    for i, row in enumerate(rows):
        if row["fault_class"] != prev_cls:
            if prev_cls is not None:
                mid = (grp_start + i - 1) / 2
                ps.note(ax, 1.01, mid, prev_cls, transform=ax.get_yaxis_transform(),
                        fontsize=8, color=CLASS_COLOURS.get(prev_cls, "#555"),
                        fontweight="bold", va="center", ha="left")
            prev_cls = row["fault_class"]
            grp_start = i
    if prev_cls:
        mid = (grp_start + n - 1) / 2
        ps.note(ax, 1.01, mid, prev_cls, transform=ax.get_yaxis_transform(),
                fontsize=8, color=CLASS_COLOURS.get(prev_cls, "#555"),
                fontweight="bold", va="center", ha="left")

    # ── Detection threshold line ──────────────────────────────────────────
    ax.axvline(THRESH, color="#888888", linestyle="--", linewidth=1.2, zorder=2,
               label=f"z = {Z_THRESHOLD} threshold")
    ps.note(ax, THRESH + 0.005, -0.8, f"threshold\n(z={Z_THRESHOLD})",
            fontsize=7, color="#666666", va="top", ha="left")

    ax.set_xlim(-0.03, 1.08)
    ax.set_ylim(-0.8, n - 0.2)
    ax.invert_yaxis()
    ax.set_xlabel("Signal strength (normalised z-score, log-scale)", fontsize=10)
    ax.grid(axis="x", alpha=0.25)

    # ── Legend ────────────────────────────────────────────────────────────
    ax.legend(handles=_detection_legend_items(rows), fontsize=8, loc="lower right",
              bbox_to_anchor=(1.0, -0.02), framealpha=0.9)

    fig.tight_layout()
    out_path = out_dir / "fig_detection_matrix.png"
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"[fig_matrix] Saved → {out_path}")


# ---------------------------------------------------------------------------
# Figure 3: Reliable detection by fault class
# ---------------------------------------------------------------------------

def fig_detection_by_class(fault_data: dict[str, dict], out_dir: Path) -> None:
    """
    Detection Coverage by Fault Class (replaces RTT signatures).

    For each fault class, a stacked bar shows how many faults fall into each
    detection outcome category (for Prometheus and Beyla separately):

      ■ Both reliable   — both methods detect in ALL runs
      ■ Prom only       — Prom reliable, Beyla not
      ■ Beyla only      — Beyla reliable, Prom not
      ■ Borderline      — at least one method detects in SOME runs
      ■ Neither         — neither method detects reliably

    This answers: "Which fault types are most/least detectable, and which tool
    is better for each category?"

    A second panel shows the per-fault signal strength strip (per class) to give
    the raw signal context alongside the aggregated coverage view.
    """
    if not HAS_MATPLOTLIB:
        return

    fault_order = [f[0] for f in FAULTS]
    class_order = ["Resource", "Crash", "Delay", "Partition", "Protocol"]

    # ── Categorise every fault into a detection outcome ───────────────────
    cats: dict[str, list[str]] = {cls: [] for cls in class_order}
    strip_data: dict[str, list[dict]] = {cls: [] for cls in class_order}

    for fname, label, fault_class in FAULTS:
        if fname not in fault_data:
            continue
        avg = fault_data[fname]["mean"]
        pf = avg.get("prom_detect_frac",  0.0)
        bf = avg.get("beyla_detect_frac", 0.0)
        cat = _categorise_detection_outcome(pf, bf)

        if fault_class in cats:
            cats[fault_class].append(cat)
            strip_data[fault_class].append({
                "label": fname[:2],
                "prom_sig":  _norm_z(avg.get("prom_z",  0.0)),
                "bey_sig":   _norm_z(avg.get("beyla_z", 0.0)),
                "cat": cat,
            })

    OUTCOME_COLOURS = {
        "Both reliable": "#2ca02c",
        "Prom only":     "#4e79a7",
        "Beyla only":    "#f28e2b",
        "Borderline":    "#bcbd22",
        "Neither":       "#aaaaaa",
    }
    OUTCOME_ORDER = ["Both reliable", "Prom only", "Beyla only", "Borderline", "Neither"]
    active_outcomes = [
        o for o in OUTCOME_ORDER
        if sum(cats[cls].count(o) for cls in class_order) > 0
    ]

    fig, ax = plt.subplots(figsize=(9, 6))
    ps.suptitle(
        fig,
        "Detection Coverage by Fault Class (Experiment C)\n"
        "How many faults in each class does each tool reliably detect?",
        fontsize=12, fontweight="bold"
    )

    y = np.arange(len(class_order))

    for oi, outcome in enumerate(active_outcomes):
        counts = [cats[cls].count(outcome) for cls in class_order]
        lefts  = [sum(cats[cls].count(o) for o in active_outcomes[:oi])
                  for cls in class_order]
        bars = ax.barh(y, counts, left=lefts, height=0.6,
                       color=OUTCOME_COLOURS[outcome], label=outcome,
                       edgecolor="white", linewidth=0.5)
        for bar, cnt in zip(bars, counts):
            if cnt > 0:
                bx = bar.get_x() + bar.get_width() / 2
                by = bar.get_y() + bar.get_height() / 2
                ps.label(ax, bx, by, str(cnt), ha="center", va="center",
                        fontsize=10, fontweight="bold", color="white")

    ax.set_yticks(y)
    ax.set_yticklabels(class_order, fontsize=12, fontweight="bold")
    ax.set_xlabel("Number of faults", fontsize=11)
    ps.title(
        ax,
        "Outcome per fault class  (based on detection fraction across 3 runs each)",
        clean="Detection outcome by fault class",
    )

    # Fault count annotation on the right
    for yi, cls in enumerate(class_order):
        total = len(cats[cls])
        ps.label(ax, total + 0.1, yi, f"n={total}", va="center", fontsize=9, color="#444")

    ax.legend(handles=[mpatches.Patch(color=OUTCOME_COLOURS[o], label=o)
                       for o in active_outcomes],
              fontsize=9, loc="lower right", title="Detection outcome")
    ax.set_xlim(0, max(len(cats[c]) for c in class_order) + 1.5)
    ax.grid(axis="x", alpha=0.25)

    fig.tight_layout()
    out_path = out_dir / "fig_detection_by_class.png"
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"[fig_coverage] Saved → {out_path}")


# ---------------------------------------------------------------------------
# Serialise to JSON
# ---------------------------------------------------------------------------

def _build_results_json(fault_data: dict[str, dict]) -> dict[str, Any]:
    """Build the C_results.json payload with per-fault signal data."""
    fault_order = [f[0] for f in FAULTS]

    per_fault_signals: dict[str, Any] = {}
    prom_total = beyla_total = loki_total = rtt_total = combined_total = 0
    n = len(fault_order)

    for fname in fault_order:
        if fname not in fault_data:
            continue
        avg = fault_data[fname]["mean"]
        if avg["prom_detected"]:  prom_total  += 1
        if avg["beyla_detected"]: beyla_total += 1
        if avg["loki_detected"]:  loki_total  += 1
        if avg["rtt_detected"]:   rtt_total   += 1
        # Combined = Prometheus OR Beyla (union)
        if avg["prom_detected"] or avg["beyla_detected"]:
            combined_total += 1

        per_fault_signals[fname] = {
            "label":            fault_data[fname]["label"],
            "fault_class":      fault_data[fname]["fault_class"],
            "prom_z":           round(avg["prom_z"],  4),
            "beyla_z":          round(avg["beyla_z"], 4),
            "loki_z":           round(avg["loki_z"],  4),
            "rtt_z":            round(avg["rtt_z"],   4),
            "prom_detected":    avg["prom_detected"],
            "beyla_detected":   avg["beyla_detected"],
            "loki_detected":    avg["loki_detected"],
            "rtt_detected":     avg["rtt_detected"],
        }

    prom_pct     = round(prom_total    / n * 100, 1)
    beyla_pct    = round(beyla_total   / n * 100, 1)
    combined_pct = round(combined_total / n * 100, 1)

    # Honest average detection fraction (% of runs detecting each fault, averaged
    # across all 22 faults). Lower than OR-logic because some faults are only
    # detected in a fraction of runs (borderline/unreliable detections).
    prom_frac_sum  = sum(fault_data[f]["mean"].get("prom_detect_frac", 0.0)
                        for f in fault_order if f in fault_data)
    beyla_frac_sum = sum(fault_data[f]["mean"].get("beyla_detect_frac", 0.0)
                        for f in fault_order if f in fault_data)
    combined_frac_sum = sum(
        max(fault_data[f]["mean"].get("prom_detect_frac", 0.0),
            fault_data[f]["mean"].get("beyla_detect_frac", 0.0))
        for f in fault_order if f in fault_data
    )
    prom_avg_pct     = round(prom_frac_sum  / n * 100, 1)
    beyla_avg_pct    = round(beyla_frac_sum / n * 100, 1)
    combined_avg_pct = round(combined_frac_sum / n * 100, 1)

    detection_rates = {
        # Using average fraction across runs (honest reliability estimate).
        # OR-inflated values: prom={prom_pct}%, beyla={beyla_pct}%
        "prom_1s":     prom_avg_pct, "prom_5s":   prom_avg_pct,
        "prom_15s":    prom_avg_pct, "prom_30s":  prom_avg_pct,
        "beyla_10pct":  beyla_avg_pct,
        "beyla_50pct":  beyla_avg_pct,
        "beyla_100pct": beyla_avg_pct,
        "combined":     combined_avg_pct,
        # OR-logic (max capability) rates for reference
        "prom_or_pct":     prom_pct,
        "beyla_or_pct":    beyla_pct,
        "combined_or_pct": combined_pct,
    }

    return {
        "source":                "Experiment C fault-detection study (computed from raw data)",
        "z_threshold":           Z_THRESHOLD,
        "faults_total":          n,
        "faults_detected_prometheus": prom_total,
        "faults_detected_beyla":      beyla_total,
        "faults_detected_loki":       loki_total,
        "faults_detected_rtt":        rtt_total,
        "detection_rates":            detection_rates,
        "per_fault":                  per_fault_signals,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Experiment C Fault Detection Analysis Pipeline"
    )
    parser.add_argument(
        "--data-dir", type=Path, default=DATA_ROOT,
        help="Root data directory (default: data/experiments/C)"
    )
    parser.add_argument(
        "--out-dir", type=Path, default=OUT_DIR,
        help="Output directory for figures and JSON (default: analysis/C_figures)"
    )
    parser.add_argument(
        "--no-plots", action="store_true",
        help="Skip figure generation, output JSON results only"
    )
    parser.add_argument(
        "--clean", action="store_true",
        help="Minimal figures: omit notes, callouts, and decorative titles"
    )
    args = parser.parse_args()

    data_root: Path = args.data_dir
    out_dir:   Path = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    ps.set_clean(args.clean)

    if args.no_plots:
        global HAS_MATPLOTLIB
        HAS_MATPLOTLIB = False

    print(f"[C_analysis] Data root : {data_root}")
    print(f"[C_analysis] Output dir: {out_dir}")

    if not data_root.exists():
        print(f"[ERROR] Data directory not found: {data_root}", file=sys.stderr)
        print("  Run experiments/C-fault-detection/run_all.sh first.", file=sys.stderr)
        sys.exit(1)

    # ── Load ───────────────────────────────────────────────────────────────
    print("\n[load] Computing signal strengths across all faults and runs...")
    fault_data = load_all(data_root)

    n_prom  = sum(1 for v in fault_data.values() if v["mean"]["prom_detected"])
    n_beyla = sum(1 for v in fault_data.values() if v["mean"]["beyla_detected"])
    n_loki  = sum(1 for v in fault_data.values() if v["mean"]["loki_detected"])
    n_rtt   = sum(1 for v in fault_data.values() if v["mean"]["rtt_detected"])
    total   = len(fault_data)
    print(f"  Prometheus: {n_prom}/{total}  "
          f"Beyla: {n_beyla}/{total}  "
          f"Loki: {n_loki}/{total}  "
          f"RTT: {n_rtt}/{total}")

    # ── Figures ────────────────────────────────────────────────────────────
    print("\n[figures] Generating C analysis figures...")
    fig_detection_matrix(fault_data, out_dir)
    fig_detection_by_class(fault_data, out_dir)

    # ── Write JSON ─────────────────────────────────────────────────────────
    results = _build_results_json(fault_data)

    root_results_path = Path(__file__).resolve().parent / "C_results.json"
    out_results_path  = out_dir / "C_results.json"
    for rp in [root_results_path, out_results_path]:
        try:
            rp.write_text(json.dumps(results, indent=2))
            print(f"[results] JSON written → {rp}")
        except Exception as e:
            print(f"[WARN] Could not write {rp}: {e}", file=sys.stderr)

    print("\n[C_analysis] Done.")
    print(f"  Figures : {out_dir}/fig_*.png")
    print(f"  Results : {out_results_path}")


if __name__ == "__main__":
    main()

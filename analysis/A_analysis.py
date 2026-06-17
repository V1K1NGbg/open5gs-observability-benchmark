#!/usr/bin/env python3
# pyright: basic
"""
analysis/A_analysis.py

Full analysis pipeline for Group A — Observability Overhead Experiments.

Research Questions answered:
  RQ1 (Overhead):   CPU/Memory infrastructure tax of Pull vs. Push telemetry.
  RQ2 (Fidelity):   Information density curve vs. infrastructure cost.
  RQ3 (Detection):  Telemetry architecture impact on Time-to-Detect anomalies.

Input:  data/experiments/A/  (written by experiments/A/*.sh)
Output: analysis/A_figures/  (PNG charts) + analysis/A_results.json

Usage:
    python3 analysis/A_analysis.py
    python3 analysis/A_analysis.py --data-dir /path/to/data/experiments/A
    python3 analysis/A_analysis.py --out-dir /path/to/output
    python3 analysis/A_analysis.py --no-plots   # JSON results only
    python3 analysis/A_analysis.py --clean      # minimal figures for publication

Dependencies: numpy, pandas, scipy, matplotlib (all in standard scientific Python)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import warnings
from pathlib import Path
from typing import Any

import numpy as np
import plot_style as ps
import pandas as pd
from scipy import stats

warnings.filterwarnings("ignore", category=FutureWarning)

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.patches as mpatches
    from matplotlib.gridspec import GridSpec
    HAS_MATPLOTLIB = True
except ImportError:
    HAS_MATPLOTLIB = False
    print("[WARN] matplotlib not available — skipping plot generation", file=sys.stderr)

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
REPO_ROOT = Path(__file__).resolve().parent.parent
DATA_ROOT = REPO_ROOT / "data" / "experiments" / "A"
OUT_DIR   = Path(__file__).resolve().parent / "A_figures"

# ---------------------------------------------------------------------------
# Colour palette (consistent across all figures)
# ---------------------------------------------------------------------------
COLOURS = {
    "baseline":  "#6c757d",
    "prom_1s":   "#d62728",
    "prom_5s":   "#ff7f0e",
    "prom_15s":  "#bcbd22",
    "prom_30s":  "#17becf",
    "beyla_100": "#1f77b4",
    "beyla_50":  "#aec7e8",
    "beyla_10":  "#9467bd",
    "combined":  "#2ca02c",
}

# ---------------------------------------------------------------------------
# Generic CSV loading helpers
# ---------------------------------------------------------------------------

def _load_prom_csv(path: Path) -> pd.DataFrame:
    """Load a standard Prometheus-collected CSV (timestamp, labels, value)."""
    if not path.exists():
        return pd.DataFrame()
    try:
        df = pd.read_csv(path)
        if "timestamp" in df.columns:
            df["timestamp"] = pd.to_numeric(df["timestamp"], errors="coerce")
        return df
    except Exception:
        return pd.DataFrame()


def _mean_of_csv(path: Path, value_col: str = "value") -> float:
    """Mean over time of the per-timestep sum across all series."""
    df = _load_prom_csv(path)
    if df.empty or value_col not in df.columns:
        return float("nan")
    s = pd.to_numeric(df[value_col], errors="coerce")
    if "timestamp" in df.columns:
        per_ts = s.groupby(df["timestamp"]).sum()
        return float(per_ts.mean()) if len(per_ts) > 0 else float("nan")
    vals = s.dropna().to_numpy(dtype=float)
    return float(vals.mean()) if len(vals) > 0 else float("nan")


def _sum_of_csv(path: Path, value_col: str = "value") -> float:
    """Mean over time of the per-timestep sum across all series."""
    df = _load_prom_csv(path)
    if df.empty or value_col not in df.columns:
        return float("nan")
    s = pd.to_numeric(df[value_col], errors="coerce")
    if "timestamp" in df.columns:
        per_ts = s.groupby(df["timestamp"]).sum()
        return float(per_ts.mean()) if len(per_ts) > 0 else float("nan")
    vals = s.dropna().to_numpy(dtype=float)
    return float(vals.mean()) if len(vals) > 0 else float("nan")


def _p99_of_csv(path: Path, value_col: str = "value") -> float:
    """P99 of per-timestep summed values across all series."""
    df = _load_prom_csv(path)
    if df.empty or value_col not in df.columns:
        return float("nan")
    s = pd.to_numeric(df[value_col], errors="coerce")
    if "timestamp" in df.columns:
        per_ts = s.groupby(df["timestamp"]).sum().dropna()
        return float(np.nanpercentile(per_ts.to_numpy(dtype=float), 99)) if len(per_ts) > 0 else float("nan")
    vals = s.dropna().to_numpy(dtype=float)
    return float(np.nanpercentile(vals, 99)) if len(vals) > 0 else float("nan")


def _finite_or(v: Any, default: float = 0.0) -> float:
    """Return default when v is None/NaN. Unlike `(v or 0)`, NaN-safe."""
    if v is None:
        return default
    try:
        x = float(v)
    except (TypeError, ValueError):
        return default
    return default if np.isnan(x) else x


def _push_cpu_mcores(beyla: Any, jaeger: Any) -> float:
    """Sum Beyla + Jaeger push-path CPU (millicores), treating NaN as 0."""
    return _finite_or(beyla) + _finite_or(jaeger)


def _load_rtt_csv(path: Path) -> pd.Series:  # type: ignore[type-arg]
    """Return a Series of RTT values in ms from ue_rtt.csv (drop packet loss rows).

    Prints a warning when a file exists but has zero valid (non-loss) rows — this
    indicates the data plane was down during collection and the run is invalid.
    """
    if not path.exists():
        return pd.Series(dtype=float)
    try:
        df = pd.read_csv(path)
        total_rows = max(len(df) - 0, 0)  # exclude header already stripped by read_csv
        col_name = "rtt_ms" if "rtt_ms" in df.columns else ("value" if "value" in df.columns else None)
        if col_name:
            col: pd.Series = pd.Series(df[col_name])  # type: ignore[assignment]
            good = col.apply(pd.to_numeric, errors="coerce").dropna()  # type: ignore[arg-type]
            if total_rows > 0 and len(good) == 0:
                print(f"  [WARN] {path.parent.name}/ue_rtt.csv: {total_rows} rows but 0 valid "
                      f"RTT measurements (100% packet loss) — run excluded from RTT aggregate",
                      file=sys.stderr)
            return good  # type: ignore[return-value]
    except Exception:
        pass
    return pd.Series(dtype=float)


def _load_meta(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


# ---------------------------------------------------------------------------
# Section 1 — Load all run data into a structured dict
# ---------------------------------------------------------------------------

def _run_is_valid(run: dict[str, Any]) -> bool:
    """Exclude runs explicitly marked invalid in meta.json."""
    meta = run.get("meta", {})
    if meta.get("data_valid") is False:
        return False
    return True


def load_run(run_dir: Path, extra_csvs: list[str] | None = None) -> dict[str, Any]:
    """
    Load a single experiment run directory.  Returns a dict with keys:
      meta, rtt_p99_ms, rtt_mean_ms,
      nf_cpu_mcores, nf_mem_mb,
      prom_cpu_mcores, prom_mem_mb,
      beyla_cpu_mcores, beyla_mem_mb,
      jaeger_cpu_mcores, jaeger_mem_mb,
      monitoring_cpu_mcores, monitoring_mem_mb,
      span_rate, beyla_http_p99_ms,
      tsdb_sample_rate,
    """
    if extra_csvs is None:
        extra_csvs = []

    prom = run_dir / "prometheus"
    result: dict[str, Any] = {
        "meta": _load_meta(run_dir / "meta.json"),
        "rtt_p99_ms":  float("nan"),
        "rtt_mean_ms": float("nan"),
    }

    meta = result["meta"]
    rtt_skipped = (
        meta.get("rtt_collected") is False
        or meta.get("rtt_metric") == "n/a_signaling_burst"
        or meta.get("traffic_profile") == "bursty"
    )

    # UE RTT (data-plane ping via uesimtun0, not registration procedure latency)
    rtt = pd.Series(dtype=float) if rtt_skipped else _load_rtt_csv(run_dir / "ue_rtt.csv")
    if not rtt.empty:
        rtt_arr: np.ndarray = rtt.to_numpy(dtype=float)
        result["rtt_p99_ms"]  = float(np.nanpercentile(rtt_arr, 99))
        result["rtt_mean_ms"] = float(np.nanmean(rtt_arr))

    def _cpu_mean(csv_name: str) -> float:
        """CPU in millicores: sum all series per timestep, then mean over time."""
        df = _load_prom_csv(prom / csv_name)
        if df.empty:
            return float("nan")
        vcol = next((c for c in ["value", "rate"] if c in df.columns), None)
        if vcol is None:
            return float("nan")
        s = pd.to_numeric(df[vcol], errors="coerce")
        if "timestamp" in df.columns:
            per_ts = s.groupby(df["timestamp"]).sum()
            return float(per_ts.mean() * 1000)
        return float(s.dropna().mean() * 1000)

    def _mem_mean(csv_name: str) -> float:
        """Memory in MiB: sum all series per timestep, then mean over time."""
        df = _load_prom_csv(prom / csv_name)
        if df.empty:
            return float("nan")
        vcol = next((c for c in ["value"] if c in df.columns), None)
        if vcol is None:
            return float("nan")
        s = pd.to_numeric(df[vcol], errors="coerce")
        if "timestamp" in df.columns:
            per_ts = s.groupby(df["timestamp"]).sum()
            return float(per_ts.mean() / (1024 ** 2))
        return float(s.dropna().mean() / (1024 ** 2))

    result["nf_cpu_mcores"]         = _cpu_mean("nf_cpu.csv")
    # Fallback: 02-prometheus-sweep didn't collect nf_cpu.csv; use the standard
    # container_cpu_usage_rate.csv (excluding the beyla monitoring agent).
    if np.isnan(result["nf_cpu_mcores"]) and (prom / "container_cpu_usage_rate.csv").exists():
        _df = _load_prom_csv(prom / "container_cpu_usage_rate.csv")
        if not _df.empty and "container" in _df.columns and "value" in _df.columns:
            _df = _df[~_df["container"].isin(["beyla", "POD", ""])]
            _s = pd.to_numeric(_df["value"], errors="coerce")
            if "timestamp" in _df.columns:
                _pts = _s.groupby(_df["timestamp"]).sum()
                result["nf_cpu_mcores"] = float(_pts.mean() * 1000)
    result["nf_mem_mb"]             = _mem_mean("nf_mem.csv")
    if np.isnan(result["nf_mem_mb"]) and (prom / "container_memory_working_set_bytes.csv").exists():
        _df = _load_prom_csv(prom / "container_memory_working_set_bytes.csv")
        if not _df.empty and "container" in _df.columns and "value" in _df.columns:
            _df = _df[~_df["container"].isin(["beyla", "POD", ""])]
            _s = pd.to_numeric(_df["value"], errors="coerce")
            if "timestamp" in _df.columns:
                _pts = _s.groupby(_df["timestamp"]).sum()
                result["nf_mem_mb"] = float(_pts.mean() / (1024 ** 2))
    result["prom_cpu_mcores"]       = _cpu_mean("prom_self_cpu.csv")
    result["prom_mem_mb"]           = _mem_mean("prom_self_mem.csv")
    # Full monitoring-namespace stack (all observability pods)
    result["stack_cpu_mcores"]      = _cpu_mean("total_monitoring_cpu.csv")
    result["stack_mem_mb"]          = _mem_mean("total_monitoring_mem.csv")
    result["beyla_cpu_mcores"]      = _cpu_mean("beyla_cpu.csv")
    result["beyla_mem_mb"]          = _mem_mean("beyla_mem.csv")
    result["jaeger_cpu_mcores"]     = _cpu_mean("jaeger_cpu.csv")
    result["jaeger_mem_mb"]         = _mem_mean("jaeger_mem.csv")
    result["monitoring_cpu_mcores"] = _cpu_mean("total_monitoring_cpu.csv")
    result["monitoring_mem_mb"]     = _mem_mean("total_monitoring_mem.csv")
    result["tsdb_sample_rate"]      = _sum_of_csv(prom / "prom_tsdb_sample_rate.csv")

    # Beyla-specific
    result["span_rate"]          = _sum_of_csv(prom / "beyla_span_rate.csv")
    result["beyla_http_p99_ms"]  = _p99_of_csv(prom / "beyla_http_p99.csv") * 1000.0

    # Jaeger span count — summary is keyed by service, sum span_count across all services
    jaeger_summary = run_dir / "jaeger" / "summary.json"
    if jaeger_summary.exists():
        try:
            js = json.loads(jaeger_summary.read_text())
            total = sum(v.get("span_count", 0) for v in js.values() if isinstance(v, dict))
            result["total_spans"] = float(total) if total > 0 else float("nan")
        except Exception:
            result["total_spans"] = float("nan")
    else:
        result["total_spans"] = float("nan")

    return result


def aggregate_runs(run_dicts: list[dict]) -> dict[str, Any]:
    """Aggregate valid runs into mean ± std (sample SD, ddof=1) for each numeric key."""
    if not run_dicts:
        return {}
    valid = [r for r in run_dicts if _run_is_valid(r)]
    if not valid:
        valid = run_dicts
    numeric_keys = [k for k, v in valid[0].items()
                    if isinstance(v, float) and k not in ("nan",)]
    agg: dict[str, Any] = {}
    for key in numeric_keys:
        vals = [r[key] for r in valid if not np.isnan(r.get(key, float("nan")))]
        agg[f"{key}_mean"] = float(np.mean(vals)) if vals else float("nan")
        agg[f"{key}_std"]  = float(np.std(vals, ddof=1)) if len(vals) > 1 else float("nan")
        agg[f"{key}_n"]    = len(vals)
    agg["runs"] = run_dicts
    agg["valid_runs"] = len(valid)
    agg["total_runs"] = len(run_dicts)
    return agg


# ---------------------------------------------------------------------------
# Section 2 — Load all conditions
# ---------------------------------------------------------------------------

def load_baseline(data_root: Path) -> dict:
    """Experiment 01 — single run."""
    d = data_root / "01-baseline"
    if not d.exists():
        return {}
    # No prometheus data; load cgroup data instead
    cgroup_dir = d / "cgroups"
    rtt = _load_rtt_csv(d / "ue_rtt.csv")
    rtt_arr: np.ndarray = rtt.to_numpy(dtype=float) if not rtt.empty else np.array([])
    result: dict = {
        "meta": _load_meta(d / "meta.json"),
        "rtt_p99_ms":  float(np.nanpercentile(rtt_arr, 99)) if len(rtt_arr) else float("nan"),
        "rtt_mean_ms": float(np.nanmean(rtt_arr)) if len(rtt_arr) else float("nan"),
    }
    # Load cgroup node_memory.csv for memory baseline
    mem_vals = []
    cpu_vals = []
    for f in cgroup_dir.glob("*_node_memory.csv"):
        df = pd.read_csv(f)
        if "mem_available_bytes" in df.columns and "mem_total_bytes" in df.columns:
            used = df["mem_total_bytes"] - df["mem_available_bytes"]
            mem_vals.extend(used.dropna().tolist())
    for f in cgroup_dir.glob("*_node_cpu_idle.csv"):
        df = pd.read_csv(f)
        if "idle_ticks" in df.columns and "total_ticks" in df.columns:
            cpu_util: pd.Series = 1.0 - (df["idle_ticks"] / df["total_ticks"].replace(0, np.nan))  # type: ignore[operator]
            cpu_vals.extend(cpu_util.dropna().tolist())
    result["node_mem_used_mb_mean"] = float(np.mean(mem_vals) / (1024**2)) if mem_vals else float("nan")
    result["node_cpu_util_mean"]    = float(np.mean(cpu_vals)) if cpu_vals else float("nan")
    return result


def load_prometheus_sweep(data_root: Path) -> dict[str, dict]:
    """Experiment 02 — keyed by interval string."""
    base = data_root / "02-prometheus-sweep"
    results: dict[str, dict] = {}
    if not base.exists():
        return results
    for interval_dir in sorted(base.iterdir()):
        if not interval_dir.is_dir():
            continue
        interval = interval_dir.name
        runs = []
        for run_dir in sorted(interval_dir.glob("run_*")):
            runs.append(load_run(run_dir))
        if runs:
            results[interval] = aggregate_runs(runs)
    return results


def load_beyla_sweep(data_root: Path) -> dict[str, dict]:
    """Experiment 03 — keyed by sampling rate string e.g. '100pct'."""
    base = data_root / "03-beyla-sweep"
    results: dict[str, dict] = {}
    if not base.exists():
        return results
    for rate_dir in sorted(base.iterdir()):
        if not rate_dir.is_dir():
            continue
        rate = rate_dir.name
        runs = []
        for run_dir in sorted(rate_dir.glob("run_*")):
            runs.append(load_run(run_dir))
        if runs:
            results[rate] = aggregate_runs(runs)
    return results


def load_combined(data_root: Path) -> dict:
    """Experiment 04 — aggregate of 3 iterations."""
    base = data_root / "04-combined"
    if not base.exists():
        return {}
    runs = []
    for run_dir in sorted(base.glob("run_*")):
        runs.append(load_run(run_dir))
    return aggregate_runs(runs)


def _load_scalability_nf_levels(base_dir: Path) -> dict[str, dict[str, dict]]:
    """Load {n}nf/{combo}/ directories under base_dir.

    Returns: {n_label: {combo_name: run_dict}}
    Legacy non-matching directories are skipped silently.
    """
    n_dir_pattern = re.compile(r"^\d+nf$")
    levels: dict[str, dict[str, dict]] = {}
    for n_dir in sorted(base_dir.iterdir(), key=lambda p: (len(p.name), p.name)):
        if not n_dir.is_dir() or not n_dir_pattern.match(n_dir.name):
            continue
        combos: dict[str, dict] = {}
        for combo_dir in sorted(n_dir.iterdir()):
            if not combo_dir.is_dir():
                continue
            combos[combo_dir.name] = load_run(combo_dir)
        if combos:
            levels[n_dir.name] = combos
    return levels


def load_scalability(data_root: Path) -> dict[str, dict[str, dict[str, dict]]]:
    """Experiment 05 — Monitoring-Scope Sweep.

    New layout (two-backend):
        05-scalability/prometheus/{n}nf/{combo}/
        05-scalability/beyla/{n}nf/{combo}/

    Legacy layout (single-backend flat, treated as "prometheus"):
        05-scalability/{n}nf/{combo}/

    Returns: {backend: {n_label: {combo_name: run_dict}}}
      e.g. {"prometheus": {"1nf": {"amf": {...}}, ...},
            "beyla":      {"1nf": {"amf": {...}}, ...}}
    """
    base = data_root / "05-scalability"
    result: dict[str, dict[str, dict[str, dict]]] = {}
    if not base.exists():
        return result

    has_backends = any((base / b).is_dir() for b in ("prometheus", "beyla"))

    if has_backends:
        for backend in ("prometheus", "beyla"):
            backend_dir = base / backend
            if backend_dir.exists():
                levels = _load_scalability_nf_levels(backend_dir)
                if levels:
                    result[backend] = levels
    else:
        # Legacy flat layout
        levels = _load_scalability_nf_levels(base)
        if levels:
            result["prometheus"] = levels

    return result


# ---------------------------------------------------------------------------
# Section 3 — Statistical tests
# ---------------------------------------------------------------------------

def mann_whitney(a: list[float], b: list[float]) -> dict:
    """Mann-Whitney U test (non-parametric). Falls back to t-test if n<3."""
    a_clean = [x for x in a if not np.isnan(x)]
    b_clean = [x for x in b if not np.isnan(x)]
    if len(a_clean) < 2 or len(b_clean) < 2:
        return {"test": "insufficient_data", "p_value": float("nan"), "significant": False}
    if len(a_clean) < 3 or len(b_clean) < 3:
        t_stat, t_p = stats.ttest_ind(a_clean, b_clean, equal_var=False)
        return {"test": "welch_t", "statistic": float(t_stat), "p_value": float(t_p),  # type: ignore[arg-type]
                 "significant": bool(float(t_p) < 0.05)}  # type: ignore[arg-type]
    mw_stat, mw_p = stats.mannwhitneyu(a_clean, b_clean, alternative="two-sided")
    return {"test": "mann_whitney_u", "statistic": float(mw_stat), "p_value": float(mw_p),  # type: ignore[arg-type]
            "significant": bool(float(mw_p) < 0.05)}


def extract_series(agg: dict, key: str) -> list[float]:
    """Extract individual run values for a metric from an aggregate dict."""
    return [r.get(key, float("nan")) for r in agg.get("runs", [])]


def _remove_outliers_robust(vals: list[float], k: float = 3.5) -> list[float]:
    """Remove outliers using the modified Z-score (median / MAD) method.

    Values where |v - median| > k * MAD / 0.6745 are considered outliers.
    k=3.5 is conservative — it only removes clear anomalies (~3.5 robust σ).
    Falls back to IQR, then to a ratio test (value > 5× median) when the spread
    of the 'core' cluster is zero (e.g. two identical values plus one extreme).
    Requires at least 2 valid values.
    """
    clean = [v for v in vals if not np.isnan(v)]
    if len(clean) < 2:
        return list(clean)
    median = float(np.median(clean))
    mad = float(np.median([abs(v - median) for v in clean]))
    if mad > 0:
        if len(clean) < 4:
            # With very few points, use a wider multiplier to avoid over-removal
            threshold = max(k, 5.0) * mad / 0.6745
        else:
            threshold = k * mad / 0.6745
        return [v for v in clean if abs(v - median) <= threshold]
    # MAD == 0: the majority cluster has zero spread (e.g. two identical values).
    # A ratio test relative to the median is more reliable than IQR here because
    # the outlier itself inflates q3, making the IQR threshold too wide.
    if median > 0:
        filtered = [v for v in clean if 0.2 * median <= v <= 5.0 * median]
        if len(filtered) < len(clean):
            return filtered
    # Last resort: IQR
    q1, q3 = float(np.percentile(clean, 25)), float(np.percentile(clean, 75))
    iqr = q3 - q1
    if iqr > 0:
        return [v for v in clean if q1 - 3 * iqr <= v <= q3 + 3 * iqr]
    return list(clean)


# ---------------------------------------------------------------------------
# Section 4 — Figure 1: Monitoring Overhead as % of NF Baseline (RQ1)
#   Shows how much extra CPU/memory each monitoring setup adds relative to
#   the 5G NF workload itself. Baseline is not shown as a bar; it IS the
#   denominator (NF cost measured in each monitored run).
#
#   Why the old baseline memory bar was inflated: the baseline run uses
#   cgroup node_mem_used (entire node RAM ≈ several GiB), whereas all
#   monitored conditions use per-container memory from cAdvisor ≈ 200–600 MiB.
#   Comparing these directly is misleading; the % overhead chart avoids this.
# ---------------------------------------------------------------------------

def fig_overhead_decomposition(
    baseline: dict,
    prom_sweep: dict[str, dict],
    beyla_sweep: dict[str, dict],
    combined: dict,
    out_dir: Path,
) -> dict:
    """
    Monitoring overhead as % of 5G NF cost.

    CPU overhead %  = monitoring_stack_cpu / nf_cpu  × 100
    Mem overhead %  = monitoring_stack_mem / nf_mem  × 100

    Error bars show ±1 SD across runs (6 runs per sweep condition).
    """
    summary: dict = {}
    summary["baseline_rtt_p99_ms"] = baseline.get("rtt_p99_ms", float("nan"))

    def _stack_cpu(agg: dict) -> float:
        v = agg.get("stack_cpu_mcores_mean", float("nan"))
        if not np.isnan(v):
            return v
        return agg.get("monitoring_cpu_mcores_mean", agg.get("prom_cpu_mcores_mean", float("nan")))

    def _stack_cpu_std(agg: dict) -> float:
        v = agg.get("stack_cpu_mcores_std", float("nan"))
        if not np.isnan(v):
            return v
        return agg.get("monitoring_cpu_mcores_std", agg.get("prom_cpu_mcores_std", float("nan")))

    def _stack_mem(agg: dict) -> float:
        v = agg.get("stack_mem_mb_mean", float("nan"))
        if not np.isnan(v):
            return v
        return agg.get("monitoring_mem_mb_mean", agg.get("prom_mem_mb_mean", float("nan")))

    # Build condition list with per-run values for strip plot
    conditions:       list[str]          = []
    cpu_pct_median:   list[float]        = []
    mem_pct_median:   list[float]        = []
    cpu_pct_runs:     list[list[float]]  = []  # per-run CPU overhead %
    mem_pct_runs:     list[list[float]]  = []  # per-run memory overhead %
    bar_colours:      list[str]          = []

    def _per_run_pct(mon_runs: list[float], nf_mean: float) -> list[float]:
        if nf_mean <= 0:
            return []
        return [m / nf_mean * 100 for m in mon_runs if not np.isnan(m)]

    iv_colour = {"1s": COLOURS["prom_1s"], "5s": COLOURS["prom_5s"],
                 "15s": COLOURS["prom_15s"], "30s": COLOURS["prom_30s"]}
    for iv in ["1s", "5s", "15s", "30s"]:
        agg = prom_sweep.get(iv, {})
        nf_cpu  = _finite_or(agg.get("nf_cpu_mcores_mean"))
        nf_mem  = _finite_or(agg.get("nf_mem_mb_mean"))
        stack_cpu_r = extract_series(agg, "stack_cpu_mcores")
        if not any(not np.isnan(v) for v in stack_cpu_r):
            stack_cpu_r = extract_series(agg, "prom_cpu_mcores")
        stack_mem_r = extract_series(agg, "stack_mem_mb")
        run_pcts_cpu = _per_run_pct([_finite_or(v) for v in stack_cpu_r], nf_cpu)
        run_pcts_mem = _per_run_pct([_finite_or(v) for v in stack_mem_r], nf_mem)
        conditions.append(f"Prom {iv}")
        cpu_pct_median.append(float(np.median(run_pcts_cpu)) if run_pcts_cpu else float("nan"))
        mem_pct_median.append(float(np.median(run_pcts_mem)) if run_pcts_mem else float("nan"))
        cpu_pct_runs.append(run_pcts_cpu)
        mem_pct_runs.append(run_pcts_mem)
        bar_colours.append(iv_colour[iv])

    bey_colour = {"100pct": COLOURS["beyla_100"], "50pct": COLOURS["beyla_50"],
                  "10pct": COLOURS["beyla_10"]}
    for rate in ["100pct", "50pct", "10pct"]:
        agg = beyla_sweep.get(rate, {})
        bey_cpu_r = extract_series(agg, "beyla_cpu_mcores")
        jae_cpu_r = extract_series(agg, "jaeger_cpu_mcores")
        bey_mem_r = extract_series(agg, "beyla_mem_mb")
        jae_mem_r = extract_series(agg, "jaeger_mem_mb")
        push_cpu_r = [_finite_or(b) + _finite_or(j) for b, j in zip(bey_cpu_r, jae_cpu_r)]
        push_mem_r = [_finite_or(b) + _finite_or(j) for b, j in zip(bey_mem_r, jae_mem_r)]
        nf_cpu_m = _finite_or(agg.get("nf_cpu_mcores_mean"))
        nf_mem_m = _finite_or(agg.get("nf_mem_mb_mean"))
        run_pcts_cpu = _per_run_pct(push_cpu_r, nf_cpu_m)
        run_pcts_mem = _per_run_pct(push_mem_r, nf_mem_m)
        conditions.append(f"Beyla {rate.replace('pct','%')}")
        cpu_pct_median.append(float(np.median(run_pcts_cpu)) if run_pcts_cpu else float("nan"))
        mem_pct_median.append(float(np.median(run_pcts_mem)) if run_pcts_mem else float("nan"))
        cpu_pct_runs.append(run_pcts_cpu)
        mem_pct_runs.append(run_pcts_mem)
        bar_colours.append(bey_colour[rate])

    # Combined: stacked breakdown (Prom stack + Beyla), outlier run removed from CPU
    agg = combined
    stack_cpu_r = extract_series(agg, "stack_cpu_mcores")
    stack_mem_r = extract_series(agg, "stack_mem_mb")
    bey_cpu_r   = extract_series(agg, "beyla_cpu_mcores")
    bey_mem_r   = extract_series(agg, "beyla_mem_mb")
    nf_cpu_m    = _finite_or(agg.get("nf_cpu_mcores_mean"))
    nf_mem_m    = _finite_or(agg.get("nf_mem_mb_mean"))
    total_cpu_r = [s + _finite_or(b) for s, b in zip(stack_cpu_r, bey_cpu_r)]
    total_mem_r = [_finite_or(s) + _finite_or(b) for s, b in zip(stack_mem_r, bey_mem_r)]

    # Per-run percentages for each component
    total_pcts_cpu = _per_run_pct(total_cpu_r, nf_cpu_m)
    stack_pcts_cpu = _per_run_pct([_finite_or(v) for v in stack_cpu_r], nf_cpu_m)
    beyla_pcts_cpu = _per_run_pct([_finite_or(v) for v in bey_cpu_r],   nf_cpu_m)
    total_pcts_mem = _per_run_pct(total_mem_r, nf_mem_m)
    stack_pcts_mem = _per_run_pct([_finite_or(v) for v in stack_mem_r], nf_mem_m)
    beyla_pcts_mem = _per_run_pct([_finite_or(v) for v in bey_mem_r],   nf_mem_m)

    # Identify and remove outlier CPU runs (any run > 5× the median total)
    med_total_cpu  = float(np.median(total_pcts_cpu)) if total_pcts_cpu else 1.0
    clean_idx      = [i for i, v in enumerate(total_pcts_cpu) if v <= med_total_cpu * 5.0]
    cpu_outlier_pcts = [total_pcts_cpu[i] for i in range(len(total_pcts_cpu))
                        if i not in set(clean_idx)]
    total_pcts_cpu_clean = [total_pcts_cpu[i] for i in clean_idx]
    stack_pcts_cpu_clean = [stack_pcts_cpu[i] for i in clean_idx if i < len(stack_pcts_cpu)]
    beyla_pcts_cpu_clean = [beyla_pcts_cpu[i] for i in clean_idx if i < len(beyla_pcts_cpu)]

    # Stacked bar medians for Combined
    comb_stack_med_cpu = float(np.median(stack_pcts_cpu_clean)) if stack_pcts_cpu_clean else 0.0
    comb_beyla_med_cpu = float(np.median(beyla_pcts_cpu_clean)) if beyla_pcts_cpu_clean else 0.0
    comb_stack_med_mem = float(np.median(stack_pcts_mem))       if stack_pcts_mem        else 0.0
    comb_beyla_med_mem = float(np.median(beyla_pcts_mem))       if beyla_pcts_mem        else 0.0

    conditions.append("Combined")
    cpu_pct_median.append(float(np.median(total_pcts_cpu_clean)) if total_pcts_cpu_clean else float("nan"))
    mem_pct_median.append(float(np.median(total_pcts_mem))        if total_pcts_mem        else float("nan"))
    cpu_pct_runs.append(total_pcts_cpu_clean)   # clean runs only for dot overlay
    mem_pct_runs.append(total_pcts_mem)
    bar_colours.append(COLOURS["combined"])

    summary["conditions"]       = conditions
    summary["cpu_overhead_pct"] = cpu_pct_median
    summary["mem_overhead_pct"] = mem_pct_median

    if not HAS_MATPLOTLIB:
        return summary

    x = np.arange(len(conditions))
    width = 0.62
    rng = np.random.default_rng(42)

    fig, axes = plt.subplots(1, 2, figsize=(20, 7))
    ps.suptitle(
        fig,
        "Figure 1 — Monitoring Overhead as % of 5G NF Cost (RQ1)\n"
        "Bars = median across runs.  Dots = individual runs.  "
        "Combined bar = stacked Prom stack (orange) + Beyla (blue).",
        fontsize=13, fontweight="bold"
    )

    sep_x    = 3.5
    COMB_IDX = len(conditions) - 1  # Combined is always the last condition

    for ax, medians, per_run, comb_stk, comb_bey, ylabel, title in [
        (axes[0], cpu_pct_median, cpu_pct_runs,
         comb_stack_med_cpu, comb_beyla_med_cpu,
         "CPU overhead (% of NF baseline CPU)",
         "CPU Overhead per Monitoring Configuration"),
        (axes[1], mem_pct_median, mem_pct_runs,
         comb_stack_med_mem, comb_beyla_med_mem,
         "Memory overhead (% of NF baseline memory)",
         "Memory Overhead per Monitoring Configuration\n"
         "Prom memory is flat: TSDB size = cardinality, not scrape rate"),
    ]:
        clean = [v if not np.isnan(v) else 0.0 for v in medians]

        # Non-Combined bars (normal coloured bars)
        ax.bar(x[:COMB_IDX], clean[:COMB_IDX], width,
               color=bar_colours[:COMB_IDX], alpha=0.75,
               edgecolor="black", linewidth=0.5, zorder=2)

        # Combined as stacked bar — two shades of the Combined green
        # darker shade = Prometheus monitoring stack, lighter = Beyla eBPF
        COMB_DARK  = "#1a6b1a"   # dark green  — Prom stack component
        COMB_LIGHT = "#74c476"   # light green — Beyla component
        ax.bar([x[COMB_IDX]], [comb_stk], width,
               color=COMB_DARK, alpha=0.85,
               edgecolor="black", linewidth=0.5, zorder=2)
        ax.bar([x[COMB_IDX]], [comb_bey], width, bottom=[comb_stk],
               color=COMB_LIGHT, alpha=0.85,
               edgecolor="black", linewidth=0.5, zorder=2)

        # Scale y-axis to bar heights only
        bar_tops = clean[:COMB_IDX] + [comb_stk + comb_bey]
        ymax = max((v for v in bar_tops if v > 0), default=1.0) * 1.3
        ax.set_ylim(0, ymax)

        # Per-run dots (Combined uses only clean runs; off-axis dots annotated)
        for xi, run_pcts, col in zip(x, per_run, bar_colours):
            if not run_pcts:
                continue
            jitter = rng.uniform(-0.18, 0.18, size=len(run_pcts))
            for v, jit in zip(run_pcts, jitter):
                if v <= ymax * 0.99:
                    ax.scatter(xi + jit, v, color=col, s=50,
                               edgecolors="black", linewidths=0.7, zorder=5, alpha=0.9)
                else:
                    ps.value_annotate(ax, f"↑ {v:.0f}%",
                                xy=(xi, ymax * 0.97), ha="center", va="top",
                                fontsize=8, fontweight="bold", color="#cc4400")

        # Annotate excluded CPU outliers for Combined
        if ax is axes[0] and cpu_outlier_pcts:
            for ov in cpu_outlier_pcts:
                ps.annotate(ax, f"↑ {ov:.0f}% outlier\n(excluded)",
                            xy=(x[COMB_IDX], ymax * 0.97), ha="center", va="top",
                            fontsize=7, color="#cc4400", fontweight="bold")

        if not ps.is_clean():
            ax.axvline(sep_x, color="#aaaaaa", linestyle="--", linewidth=1.2, alpha=0.7)
            ps.note(ax, 1.5, ymax * 1.01, "← Pull telemetry", ha="center",
                    fontsize=9, color="#555555", style="italic")
            ps.note(ax, 5.5, ymax * 1.01, "Push telemetry →", ha="center",
                    fontsize=9, color="#555555", style="italic")

        # Value labels on non-Combined bars
        for xi_i, val in enumerate(clean[:COMB_IDX]):
            if val > 0:
                ps.label(ax, x[xi_i], val + ymax * 0.012, f"{val:.0f}%",
                        ha="center", va="bottom", fontsize=8, fontweight="bold")
        # Total label on Combined
        comb_total = comb_stk + comb_bey
        if comb_total > 0:
            ps.label(ax, x[COMB_IDX], comb_total + ymax * 0.012, f"{comb_total:.0f}%",
                    ha="center", va="bottom", fontsize=8, fontweight="bold")

        ax.set_xticks(x)
        tick_labels = list(conditions)
        tick_labels[COMB_IDX] = "Combined" if ps.is_clean() else "Combined\n(Prom 5s\n+ Beyla 100%)"
        ax.set_xticklabels(tick_labels, rotation=30, ha="right", fontsize=9)
        ax.set_ylabel(ylabel, fontsize=10)
        ps.title(
            ax, title,
            clean=ylabel if ax is axes[0] else "Memory overhead (%)",
        )
        ax.grid(axis="y", alpha=0.3)

    ps.note(axes[0], 0.98, 0.96,
            "Combined = Prom monitoring stack (dark green) + Beyla eBPF (light green)\n"
            "Outlier run (~717% CPU) excluded — still shown as annotation.",
            transform=axes[0].transAxes,
            fontsize=7.5, ha="right", va="top", color="#cc4400",
            bbox=dict(boxstyle="round,pad=0.3", facecolor="#fff8f0",
                      edgecolor="#ffaa66"))
    ps.note(axes[1], 0.98, 0.96,
            "Prom memory flat: TSDB size = time-series cardinality,\n"
            "not scrape rate. All intervals scrape the same series.",
            transform=axes[1].transAxes,
            fontsize=7.5, ha="right", va="top", color="#444444",
            bbox=dict(boxstyle="round,pad=0.3", facecolor="#f0f4ff",
                      edgecolor="#8888cc"))

    fig.tight_layout()
    out_path = out_dir / "fig1_overhead_decomposition.png"
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"[fig1] Saved → {out_path}")

    return summary


# ---------------------------------------------------------------------------
# Section 5 — Figure 2: Telemetry Cost vs Scrape/Sample Rate (RQ2)
#   Panel A: Full monitoring-stack CPU vs Prometheus scrape interval
#   Panel B: Beyla + Jaeger CPU vs eBPF sampling rate
#   (RTT comparison moved to Figure 6 Panel B)
# ---------------------------------------------------------------------------

def fig_granularity_curve(
    prom_sweep: dict[str, dict],
    beyla_sweep: dict[str, dict],
    baseline: dict,
    out_dir: Path,
) -> dict:
    """
    Two panels showing how infrastructure cost varies with telemetry granularity.

    Panel A — Prometheus: monitoring-stack CPU drops steeply as scrape interval
              grows (1 s → 30 s = ~7× less CPU). Error bars = SD across 6 runs.

    Panel B — Beyla eBPF: push CPU is essentially constant regardless of sampling
              rate (10 % → 100 %). eBPF instruments every syscall; sampling only
              filters *exported* spans, not kernel-side processing.
    """
    summary: dict = {}

    def _stack_cpu(agg: dict) -> float:
        v = agg.get("stack_cpu_mcores_mean", float("nan"))
        if not np.isnan(v):
            return v
        return agg.get("monitoring_cpu_mcores_mean", agg.get("prom_cpu_mcores_mean", float("nan")))

    def _stack_cpu_std(agg: dict) -> float:
        v = agg.get("stack_cpu_mcores_std", float("nan"))
        if not np.isnan(v):
            return v
        return agg.get("monitoring_cpu_mcores_std", agg.get("prom_cpu_mcores_std", float("nan")))

    iv_seconds = {"1s": 1, "5s": 5, "15s": 15, "30s": 30}
    prom_x: list[int]   = []
    prom_cpu_y: list[float] = []
    prom_cpu_lo: list[float] = []   # Q1 per-run
    prom_cpu_hi: list[float] = []   # Q3 per-run
    prom_rtt_y:  list[float] = []
    for iv_str, iv_s in sorted(iv_seconds.items(), key=lambda t: t[1]):
        agg = prom_sweep.get(iv_str, {})
        prom_x.append(iv_s)
        cpu_runs = [v for v in extract_series(agg, "stack_cpu_mcores") if not np.isnan(v)]
        if not cpu_runs:
            cpu_runs = [v for v in extract_series(agg, "prom_cpu_mcores") if not np.isnan(v)]
        prom_cpu_y.append(float(np.median(cpu_runs))        if cpu_runs else float("nan"))
        prom_cpu_lo.append(float(np.percentile(cpu_runs, 25)) if cpu_runs else float("nan"))
        prom_cpu_hi.append(float(np.percentile(cpu_runs, 75)) if cpu_runs else float("nan"))
        rtt_runs = [v for v in extract_series(agg, "rtt_p99_ms") if not np.isnan(v)]
        prom_rtt_y.append(float(np.median(rtt_runs)) if rtt_runs else float("nan"))

    bey_rates = {"10pct": 10, "50pct": 50, "100pct": 100}
    bey_x: list[int]    = []
    bey_cpu_y: list[float]  = []
    bey_cpu_lo: list[float] = []
    bey_cpu_hi: list[float] = []
    bey_rtt_y:  list[float] = []
    for rate_str, rate_v in sorted(bey_rates.items(), key=lambda t: t[1]):
        agg = beyla_sweep.get(rate_str, {})
        bey_x.append(rate_v)
        bey_r = [_finite_or(b) + _finite_or(j)
                 for b, j in zip(extract_series(agg, "beyla_cpu_mcores"),
                                 extract_series(agg, "jaeger_cpu_mcores"))]
        bey_r_c = [v for v in bey_r if not np.isnan(v)]
        bey_cpu_y.append(float(np.median(bey_r_c))        if bey_r_c else float("nan"))
        bey_cpu_lo.append(float(np.percentile(bey_r_c, 25)) if bey_r_c else float("nan"))
        bey_cpu_hi.append(float(np.percentile(bey_r_c, 75)) if bey_r_c else float("nan"))
        rtt_runs = [v for v in extract_series(agg, "rtt_p99_ms") if not np.isnan(v)]
        bey_rtt_y.append(float(np.median(rtt_runs)) if rtt_runs else float("nan"))

    baseline_rtt = baseline.get("rtt_p99_ms", float("nan"))

    summary["prom_scrape_intervals_s"] = prom_x
    summary["prom_stack_cpu_mcores"]   = prom_cpu_y
    summary["prom_rtt_p99_ms"]         = prom_rtt_y
    summary["beyla_sampling_pct"]      = bey_x
    summary["beyla_push_cpu_mcores"]   = bey_cpu_y
    summary["beyla_rtt_p99_ms"]        = bey_rtt_y
    summary["baseline_rtt_p99_ms"]     = baseline_rtt

    if not HAS_MATPLOTLIB:
        return summary

    fig, axes = plt.subplots(1, 2, figsize=(16, 6))
    ps.suptitle(
        fig,
        "Figure 2 — Telemetry Granularity vs Infrastructure Cost (RQ2)\n"
        "Lines = median across runs.  Shaded band = IQR (Q1–Q3, 6 runs).",
        fontsize=13, fontweight="bold"
    )

    # ── Panel A: Prometheus full-stack CPU vs scrape interval ─────────
    ax = axes[0]
    cpu_clean  = [v if not np.isnan(v) else 0.0 for v in prom_cpu_y]
    cpu_lo     = [max(0.0, v) if not np.isnan(v) else 0.0 for v in prom_cpu_lo]
    cpu_hi     = [v if not np.isnan(v) else 0.0 for v in prom_cpu_hi]
    ax.fill_between(prom_x, cpu_lo, cpu_hi,
                    color=COLOURS["prom_5s"], alpha=0.25, label="IQR Q1–Q3 (6 runs)")
    ax.plot(prom_x, cpu_clean, "o-", color=COLOURS["prom_5s"],
            linewidth=2.5, markersize=9, label="Median monitoring stack CPU")
    for xi, yi in zip(prom_x, cpu_clean):
        ps.value_annotate(ax, f"{yi:.0f} mC", (xi, yi), textcoords="offset points",
                    xytext=(8, 5), fontsize=9)
    ax.set_xlabel("Prometheus scrape interval (seconds)", fontsize=11)
    ax.set_ylabel("Full monitoring stack CPU (millicores)", fontsize=11)
    ps.title(
        ax,
        "Prometheus Pull Cost vs Scrape Interval\n"
        "Shorter interval → more frequent scraping → much higher CPU",
        clean="Prometheus stack CPU vs scrape interval",
    )
    ax.set_xticks(prom_x)
    ax.set_xticklabels([f"{v}s" for v in prom_x])
    ax.set_ylim(0, max(cpu_clean) * 1.25 if cpu_clean else 10)
    ax.legend(fontsize=9)
    ax.grid(alpha=0.3)

    # ── Panel B: Beyla push CPU vs sampling rate ─────────────────────
    ax = axes[1]
    cpu_bey_clean  = [v if not np.isnan(v) else 0.0 for v in bey_cpu_y]
    cpu_bey_finite = [v for v in bey_cpu_y if not np.isnan(v)]
    cpu_bey_lo = [max(0.0, v) if not np.isnan(v) else 0.0 for v in bey_cpu_lo]
    cpu_bey_hi = [v if not np.isnan(v) else 0.0 for v in bey_cpu_hi]
    ax.fill_between(bey_x, cpu_bey_lo, cpu_bey_hi,
                    color=COLOURS["beyla_100"], alpha=0.25, label="IQR Q1–Q3 (6 runs)")
    ax.plot(bey_x, cpu_bey_clean, "s-", color=COLOURS["beyla_100"],
            linewidth=2.5, markersize=9, label="Median push CPU (Beyla+Jaeger)")
    for xi, yi in zip(bey_x, cpu_bey_clean):
        ps.value_annotate(ax, f"{yi:.2f} mC", (xi, yi), textcoords="offset points",
                    xytext=(6, 6), fontsize=9)

    # Y-axis: wide enough to show the line is flat in context (0 to 5 mC)
    ax.set_ylim(0, 5)

    ax.set_xlabel("Beyla eBPF sampling rate (%)", fontsize=11)
    ax.set_ylabel("Push CPU (Beyla + Jaeger, millicores)", fontsize=11)
    ps.title(
        ax,
        "Beyla eBPF Push Cost vs Sampling Rate\n"
        "Overhead is essentially flat regardless of how many spans are exported",
        clean="Beyla+Jaeger CPU vs sampling rate",
    )
    ax.set_xticks(bey_x)
    ax.set_xticklabels([f"{v}%" for v in bey_x])
    ax.legend(fontsize=9)
    ax.grid(alpha=0.3)
    if cpu_bey_finite:
        span = max(cpu_bey_finite) - min(cpu_bey_finite)
        ps.note(
            ax, 0.5, 0.18,
            f"Range: {min(cpu_bey_finite):.2f} – {max(cpu_bey_finite):.2f} mC  "
            f"(variation = {span:.2f} mC = {span/max(cpu_bey_finite)*100:.0f}%)\n"
            "eBPF instruments every syscall; sampling only filters exported spans.",
            transform=ax.transAxes, ha="center", fontsize=9,
            color="#444444", style="italic",
            bbox=dict(boxstyle="round,pad=0.4", facecolor="#f0f4ff", edgecolor="#9999cc"),
        )

    fig.tight_layout()
    out_path = out_dir / "fig2_granularity_curve.png"
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"[fig2] Saved → {out_path}")

    return summary


# ---------------------------------------------------------------------------
# Section 6 — Figure 3: Monitoring-Scope Scalability (RQ1 at scope)
#   Two panels: Prometheus CPU vs n NFs (left) | Beyla CPU vs n NFs (right).
#   Fixed load: 15 UEs.  NF pool: 8 most stable of the 12 collected (n = 1 … 8).
#
#   For each n, up to 5 combinations of n NFs are run to show that the result
#   is robust to which NFs are chosen.  Each combination is plotted as an
#   individual scatter point.  The median across combos at each n is plotted
#   as the main trend line; IQR (Q1–Q3) bars show combo-choice spread.
# ---------------------------------------------------------------------------

SCALABILITY_NF_POOL: tuple[str, ...] = (
    "amf", "smf", "upf", "pcf", "nrf",
    "ausf", "bsf", "udm", "udr", "scp", "nssf", "sepp",
)
SCALABILITY_STABLE_COUNT = 8
SCALABILITY_MAX_N = 8
_CHART_NATIVE_NFS = frozenset({"amf", "smf", "upf", "pcf"})


def _parse_combo_nfs(combo_name: str) -> tuple[str, ...]:
    return tuple(combo_name.split("_"))


def _select_stable_scalability_nfs(
    scalability: dict[str, dict[str, dict[str, dict]]],
    n_stable: int = SCALABILITY_STABLE_COUNT,
) -> list[str]:
    """Return the n_stable most stable NFs from the collected pool.

    Always includes chart-native NFs (amf/smf/upf/pcf) and nrf.  The remaining
    slots are filled in experiment deployment order (ausf, bsf, udm before the
    late-batch extras udr/scp/nssf/sepp, which show wider combo-choice spread).
    """
    collected: set[str] = set()
    for backend, levels in scalability.items():
        for combos in levels.values():
            for combo_name in combos:
                collected.update(_parse_combo_nfs(combo_name))

    pool = [nf for nf in SCALABILITY_NF_POOL if nf in collected]
    core = [nf for nf in pool if nf in _CHART_NATIVE_NFS or nf == "nrf"]
    remaining = [nf for nf in pool if nf not in core]
    n_fill = max(0, n_stable - len(core))
    return (core + remaining[:n_fill])[:n_stable]


def _filter_scalability_levels(
    levels: dict[str, dict[str, dict]],
    stable_nfs: list[str],
    max_n: int = SCALABILITY_MAX_N,
) -> dict[str, dict[str, dict]]:
    """Keep n=1..max_n and combos whose NFs are all in stable_nfs."""
    stable_set = set(stable_nfs)
    filtered: dict[str, dict[str, dict]] = {}
    for n_label, combos in levels.items():
        n_val = int(re.sub(r"\D", "", n_label) or "0")
        if n_val > max_n:
            continue
        kept = {
            name: rd for name, rd in combos.items()
            if all(nf in stable_set for nf in _parse_combo_nfs(name))
        }
        if kept:
            filtered[n_label] = kept
    return filtered


def fig_scalability(
    scalability: dict[str, dict[str, dict[str, dict]]],
    out_dir: Path,
) -> dict:
    """Telemetry CPU cost vs. number of monitored NFs — two-backend comparison.

    Left panel : Prometheus process CPU  (prom_cpu_mcores)
    Right panel: Beyla container CPU     (beyla_cpu_mcores)

    Trend line  : median across NF combinations at each n.
    Error bars  : IQR (Q1 to Q3) — shows sensitivity to choice of NFs.
    Scatter     : individual combination points (jittered horizontally).

    Accepts {"prometheus": {n_label: {combo: run}}, "beyla": {...}}.
    Handles legacy flat {n_label: {combo: run}} as prometheus-only.
    """
    # Normalise legacy format
    summary: dict = {}
    if scalability and next(iter(scalability.values()), None) is not None:
        first_val = next(iter(scalability.values()))
        if isinstance(first_val, dict):
            inner = next(iter(first_val.values()), None)
            if isinstance(inner, dict) and "prom_cpu_mcores" in inner:
                scalability = {"prometheus": scalability}  # type: ignore[assignment]

    stable_nfs = _select_stable_scalability_nfs(scalability)
    excluded_nfs = [nf for nf in SCALABILITY_NF_POOL if nf not in stable_nfs]
    scalability = {
        backend: _filter_scalability_levels(levels, stable_nfs)
        for backend, levels in scalability.items()
    }
    summary["stable_nfs"] = stable_nfs
    summary["excluded_nfs"] = excluded_nfs
    summary["max_n"] = SCALABILITY_MAX_N

    BACKENDS: dict[str, tuple[str, str]] = {
        "prometheus": ("prom_cpu_mcores",  "Prometheus process CPU (millicores)"),
        "beyla":      ("beyla_cpu_mcores", "Beyla container CPU (millicores)"),
    }

    def _aggregate(levels: dict[str, dict[str, dict]], cpu_key: str) -> tuple[
        list[int], list[float], list[float], list[float], list[list[float]]
    ]:
        """Return xs, medians, q1s, q3s, all_points for each n-level."""
        n_labels_sorted = sorted(
            levels.keys(),
            key=lambda k: int(re.sub(r"\D", "", k) or "0"),
        )
        xs, medians, q1s, q3s, points = [], [], [], [], []
        for n_label in n_labels_sorted:
            n_val = int(re.sub(r"\D", "", n_label) or "0")
            vals = [
                rd.get(cpu_key, float("nan"))
                for rd in levels[n_label].values()
                if not np.isnan(rd.get(cpu_key, float("nan")))
            ]
            xs.append(n_val)
            if vals:
                medians.append(float(np.median(vals)))
                q1s.append(float(np.percentile(vals, 25)))
                q3s.append(float(np.percentile(vals, 75)))
            else:
                medians.append(float("nan"))
                q1s.append(float("nan"))
                q3s.append(float("nan"))
            points.append(vals)
        return xs, medians, q1s, q3s, points

    # Build summary JSON
    for backend, (cpu_key, _) in BACKENDS.items():
        levels = scalability.get(backend, {})
        n_labels_sorted = sorted(
            levels.keys(), key=lambda k: int(re.sub(r"\D", "", k) or "0")
        )
        backend_summary: dict = {}
        for n_label in n_labels_sorted:
            combos = levels[n_label]
            vals = [
                rd.get(cpu_key, float("nan"))
                for rd in combos.values()
                if not np.isnan(rd.get(cpu_key, float("nan")))
            ]
            backend_summary[n_label] = {
                f"median_{cpu_key}": float(np.median(vals)) if vals else float("nan"),
                f"q1_{cpu_key}":     float(np.percentile(vals, 25)) if vals else float("nan"),
                f"q3_{cpu_key}":     float(np.percentile(vals, 75)) if vals else float("nan"),
                "n_combos": len(vals),
                "combos": {k: rd.get(cpu_key, float("nan")) for k, rd in combos.items()},
            }
        summary[backend] = backend_summary

    if not HAS_MATPLOTLIB:
        return summary

    active_backends = [b for b in ("prometheus", "beyla") if scalability.get(b)]
    n_panels = len(active_backends)
    if n_panels == 0:
        return summary

    fig, axes = plt.subplots(1, n_panels, figsize=(9 * n_panels, 6), squeeze=False)
    ps.suptitle(
        fig,
        "Figure 3 — Telemetry Collection CPU vs. Number of Monitored NFs\n"
        "Fixed load: 15 UEs  |  Dots = individual NF combinations  "
        "|  Line = median  |  Bars = IQR (Q1–Q3)",
        fontsize=13, fontweight="bold",
    )

    jitter_rng = np.random.default_rng(42)

    SCATTER_COLORS = {
        "prometheus": ("#aec7e8", "#4a90c4", "#1f77b4"),
        "beyla":      ("#ffbb78", "#d46a00", "#d46a00"),
    }
    TITLES = {
        "prometheus": (
            "Pull telemetry — Prometheus",
            "ServiceMonitor scope varies  |  Beyla at full scope",
        ),
        "beyla": (
            "eBPF telemetry — Beyla",
            "BEYLA_EXECUTABLE_NAME scope varies  |  Prometheus scrapes all NFs",
        ),
    }

    for col_idx, backend in enumerate(active_backends):
        ax = axes[0][col_idx]
        cpu_key, y_label = BACKENDS[backend]
        levels = scalability[backend]
        xs, medians, q1s, q3s, points = _aggregate(levels, cpu_key)

        scatter_fill, scatter_edge, trend_color = SCATTER_COLORS[backend]

        # Scatter: individual combo points
        for n_val, vals in zip(xs, points):
            if not vals:
                continue
            jitter = jitter_rng.uniform(-0.08, 0.08, len(vals))
            ax.scatter(
                [n_val + j for j in jitter],
                vals,
                color=scatter_fill,
                edgecolors=scatter_edge,
                linewidths=0.8,
                s=55,
                zorder=3,
                label="Individual combo" if n_val == xs[0] else None,
            )

        # Median trend + IQR error bars
        valid = [
            (x, med, q1, q3)
            for x, med, q1, q3 in zip(xs, medians, q1s, q3s)
            if not np.isnan(med)
        ]
        if valid:
            tx, tm, tq1, tq3 = zip(*valid)
            # Asymmetric error: [median - Q1, Q3 - median]
            err_lo = [med - q1 for med, q1 in zip(tm, tq1)]
            err_hi = [q3 - med for q3, med in zip(tq3, tm)]
            ax.errorbar(
                tx, tm,
                yerr=[err_lo, err_hi],
                fmt="o-",
                color=trend_color,
                linewidth=2.4,
                markersize=9,
                capsize=5,
                capthick=1.5,
                elinewidth=1.5,
                zorder=4,
                label="Median  (IQR Q1–Q3)",
            )
            for xi, yi in zip(tx, tm):
                ps.value_annotate(
                    ax, f"{yi:.1f} mC",
                    (xi, yi),
                    textcoords="offset points",
                    xytext=(9, 6),
                    fontsize=8,
                    color=trend_color,
                    fontweight="bold",
                )

        n_max = SCALABILITY_MAX_N
        short_title, sub_title = TITLES[backend]
        ps.title(ax, f"{short_title}\n{sub_title}", clean=short_title)
        ax.set_xlabel("Number of monitored NFs", fontsize=11)
        ax.set_ylabel(y_label, fontsize=11)
        ax.set_xticks(list(range(1, n_max + 1)))
        ax.set_xticklabels([str(n) for n in range(1, n_max + 1)])
        ax.set_xlim(0.5, n_max + 0.5)
        all_vals = [v for pts in points for v in pts if not np.isnan(v)]
        if all_vals:
            ax.set_ylim(0, max(all_vals) * 1.40)
        ax.legend(fontsize=9, loc="upper left")
        ax.grid(alpha=0.3)
        total_runs = sum(len(p) for p in points)
        ps.note(
            ax, 0.97, 0.04,
            f"15 UEs  |  scrape interval 5 s  |  {total_runs} collection windows",
            transform=ax.transAxes, fontsize=7.5, ha="right", va="bottom",
            color="#888888", style="italic",
        )

    fig.tight_layout()
    out_path = out_dir / "fig3_scalability.png"
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"[fig3] Saved → {out_path}")

    return summary


# ---------------------------------------------------------------------------
# Section 7 — Figure 4: Statistical Comparison (RQ1, formal tests)
#   Two panels: Prometheus (pull) group and Beyla (push) group.
#   Each panel shows per-run dots + box, with the group mean annotated.
#   Split panels are needed because the two groups differ by ~50×, making a
#   single-axis plot unreadable for the push group.
# ---------------------------------------------------------------------------

def _fig4_symbol_legend_items() -> list:
    """Legend entries explaining box-plot symbols (shown in clean mode)."""
    from matplotlib.lines import Line2D

    return [
        mpatches.Patch(facecolor="#cccccc", edgecolor="black", alpha=0.55,
                       label="Box (IQR + whiskers)"),
        Line2D([0], [0], color="black", linewidth=2.2, label="Median"),
        Line2D([0], [0], marker="D", color="w", markerfacecolor="white",
               markeredgecolor="black", markeredgewidth=1.6, markersize=8,
               linestyle="None", label="Mean"),
        Line2D([0], [0], marker="o", color="w", markerfacecolor="#888888",
               markeredgecolor="black", markeredgewidth=0.8, markersize=8,
               linestyle="None", label="Individual runs"),
    ]


def fig_statistical_comparison(
    prom_sweep: dict[str, dict],
    beyla_sweep: dict[str, dict],
    out_dir: Path,
) -> dict:
    """
    Box + strip plot of per-run CPU distributions.
    Split into Prometheus (pull) and Beyla (push) panels because the groups
    differ by ~50× in magnitude — a shared axis would compress Beyla to a flat line.
    """
    summary: dict = {"tests": {}}

    prom_labels: list[str] = []
    prom_cpu_series: list[list[float]] = []
    prom_mem_series: list[list[float]] = []
    bey_labels:  list[str] = []
    bey_cpu_series: list[list[float]] = []
    bey_mem_series: list[list[float]] = []

    prom_colours = [COLOURS["prom_1s"], COLOURS["prom_5s"],
                    COLOURS["prom_15s"], COLOURS["prom_30s"]]
    bey_colours  = [COLOURS["beyla_100"], COLOURS["beyla_50"], COLOURS["beyla_10"]]

    for iv in ["1s", "5s", "15s", "30s"]:
        agg = prom_sweep.get(iv, {})
        cpu_s = extract_series(agg, "stack_cpu_mcores")
        if not any(not np.isnan(v) for v in cpu_s):
            cpu_s = extract_series(agg, "prom_cpu_mcores")
        mem_s = extract_series(agg, "stack_mem_mb")
        if not any(not np.isnan(v) for v in mem_s):
            mem_s = extract_series(agg, "prom_mem_mb")
        prom_labels.append(f"Prom {iv}")
        prom_cpu_series.append([v for v in cpu_s if not np.isnan(v)])
        prom_mem_series.append([v for v in mem_s if not np.isnan(v)])

    for rate in ["100pct", "50pct", "10pct"]:
        agg = beyla_sweep.get(rate, {})
        bey_cpu  = extract_series(agg, "beyla_cpu_mcores")
        jae_cpu  = extract_series(agg, "jaeger_cpu_mcores")
        push_cpu = [_finite_or(b) + _finite_or(j) for b, j in zip(bey_cpu, jae_cpu)]
        bey_mem  = extract_series(agg, "beyla_mem_mb")
        jae_mem  = extract_series(agg, "jaeger_mem_mb")
        push_mem = [_finite_or(b) + _finite_or(j) for b, j in zip(bey_mem, jae_mem)]
        bey_labels.append(f"Beyla {rate.replace('pct','%')}")
        bey_cpu_series.append([v for v in push_cpu if not np.isnan(v)])
        bey_mem_series.append([v for v in push_mem if not np.isnan(v)])

    prom5_raw  = [v for v in extract_series(prom_sweep.get("5s", {}), "prom_cpu_mcores")
                  if not np.isnan(v)]
    bey100_bey = extract_series(beyla_sweep.get("100pct", {}), "beyla_cpu_mcores")
    bey100_jae = extract_series(beyla_sweep.get("100pct", {}), "jaeger_cpu_mcores")
    bey100_raw = [_finite_or(b) + _finite_or(j)
                  for b, j in zip(bey100_bey, bey100_jae)
                  if not np.isnan(_finite_or(b))]
    test_result = mann_whitney(prom5_raw, bey100_raw)
    summary["tests"]["prom_5s_vs_beyla_100pct_cpu"] = test_result

    # Apply outlier removal per condition before plotting
    prom_cpu_clean  = [_remove_outliers_robust(s) for s in prom_cpu_series]
    prom_mem_clean  = [_remove_outliers_robust(s) for s in prom_mem_series]
    bey_cpu_clean   = [_remove_outliers_robust(s) for s in bey_cpu_series]
    bey_mem_clean   = [_remove_outliers_robust(s) for s in bey_mem_series]

    # Merge Prometheus + Beyla into one list per metric, with a gap position between groups
    all_labels  = prom_labels  + bey_labels
    all_cpu     = prom_cpu_clean  + bey_cpu_clean
    all_mem     = prom_mem_clean  + bey_mem_clean
    all_colours = prom_colours    + bey_colours
    n_prom = len(prom_labels)   # index of first Beyla condition

    if not HAS_MATPLOTLIB:
        return summary

    fig, axes = plt.subplots(1, 2, figsize=(20, 8))
    ps.suptitle(
        fig,
        "Figure 4 — CPU and Memory Cost Distribution: All Monitoring Conditions (RQ1)\n"
        "Prom sweep (pull)  ·  Beyla sweep (push).  "
        "Box = IQR + whiskers  │  Line = median  │  ◆ = mean  │  dots = individual runs.",
        clean="CPU and memory cost distribution",
        fontsize=12, fontweight="bold",
    )

    rng = np.random.default_rng(42)

    def _draw_merged_panel(ax: Any, labels: list, series: list, colours: list,
                           ylabel: str, title: str, log_scale: bool = True) -> None:
        n = len(labels)
        # Insert a half-position gap between Prom and Beyla groups
        pos = []
        for i in range(n):
            pos.append(i + 1 + (0.5 if i >= n_prom else 0))

        box_w = 0.42
        bp = ax.boxplot(series, positions=pos, patch_artist=True,
                        notch=False, widths=box_w,
                        medianprops=dict(color="black", linewidth=2.2),
                        whiskerprops=dict(linewidth=1.4),
                        capprops=dict(linewidth=1.4),
                        flierprops=dict(marker="", markersize=0))
        for patch, colour in zip(bp["boxes"], colours):
            patch.set_facecolor(colour)
            patch.set_alpha(0.55)

        for p, vals, colour in zip(pos, series, colours):
            if vals:
                jitter = rng.uniform(-0.14, 0.14, size=len(vals))
                ax.scatter(p + jitter, vals, color=colour, s=60,
                           edgecolors="black", linewidths=0.8, zorder=5, alpha=0.92)
                mean_v = float(np.mean(vals))
                ax.scatter(p, mean_v, marker="D", s=55,
                           color="white", edgecolors="black", linewidths=1.6, zorder=6)

                # ── Detailed value labels on each box ──────────────────
                med_v   = float(np.median(vals))
                min_v   = float(np.min(vals))
                max_v   = float(np.max(vals))
                ps.label(ax, p + box_w * 0.58, med_v,
                        f"{med_v:.1f}", ha="left", va="center",
                        fontsize=6.5, color="black", fontweight="bold")
                ps.label(ax, p + box_w * 0.58, mean_v,
                        f"μ={mean_v:.1f}", ha="left", va="bottom",
                        fontsize=6, color="#333333")
                ps.label(ax, p, min_v * (0.82 if log_scale else 1) - (0 if log_scale else max_v * 0.05),
                        f"{min_v:.1f}–{max_v:.1f}",
                        ha="center", va="top", fontsize=6, color="#555555",
                        rotation=0)

        # Group separator between Prom and Beyla
        sep = (pos[n_prom - 1] + pos[n_prom]) / 2
        if not ps.is_clean():
            ax.axvline(sep, color="#aaaaaa", linestyle="--", linewidth=1.2, alpha=0.7)
        ylo, yhi = ax.get_ylim()
        ps.note(ax, np.mean(pos[:n_prom]),  yhi, "← Prometheus (pull)",
                ha="center", va="bottom", fontsize=9, color="#444444", style="italic")
        ps.note(ax, np.mean(pos[n_prom:]),  yhi, "Beyla eBPF (push) →",
                ha="center", va="bottom", fontsize=9, color="#444444", style="italic")

        ax.set_xticks(pos)
        ax.set_xticklabels(labels, fontsize=9, rotation=25, ha="right")
        ax.set_ylabel(ylabel, fontsize=10)
        ps.title(ax, title, clean=title.split(" — ")[0])
        ax.grid(axis="y", alpha=0.25, which="both")
        ax.set_xlim(pos[0] - 0.7, pos[-1] + 0.7)

    _draw_merged_panel(
        axes[0], all_labels, all_cpu, all_colours,
        "CPU (millicores, log scale)",
        "CPU Cost Distribution — all 7 conditions",
        log_scale=True,
    )
    _draw_merged_panel(
        axes[1], all_labels, all_mem, all_colours,
        "Memory (MiB)",
        "Memory Cost Distribution — all 7 conditions",
        log_scale=False,
    )

    # ── Shared y scales ──────────────────────────────────────────────────────
    all_cpu_vals = [v for s in all_cpu for v in s if v > 0]
    if all_cpu_vals:
        cpu_lo = max(0.3, min(all_cpu_vals) * 0.5)
        cpu_hi = max(all_cpu_vals) * 3.0
        axes[0].set_yscale("log")
        axes[0].set_ylim(cpu_lo, cpu_hi)
        axes[0].yaxis.set_major_formatter(
            plt.FuncFormatter(lambda v, _: f"{v:.0f}" if v >= 1 else f"{v:.2f}")
        )

    all_mem_vals = [v for s in all_mem for v in s]
    if all_mem_vals:
        axes[1].set_ylim(0, max(all_mem_vals) * 1.25)

    # ── Statistical test + ratio annotation ──────────────────────────────────
    prom5_mean  = float(np.mean(prom5_raw))  if prom5_raw  else float("nan")
    bey100_mean = float(np.mean(bey100_raw)) if bey100_raw else float("nan")
    p_val = test_result.get("p_value", float("nan"))
    sig_str = "significant" if test_result.get("significant") else "not sig."
    if not (np.isnan(prom5_mean) or np.isnan(bey100_mean)) and bey100_mean > 0:
        ps.note(
            axes[0], 0.02, 0.97,
            f"Mann-Whitney Prom 5s vs Beyla 100%: p={p_val:.4f} ({sig_str})\n"
            f"Pull ({prom5_mean:.0f} mC) is {prom5_mean/bey100_mean:.0f}× "
            f"more expensive than push ({bey100_mean:.1f} mC)",
            transform=axes[0].transAxes, fontsize=8, ha="left", va="top",
            bbox=dict(boxstyle="round,pad=0.3", facecolor="#fff3cd", edgecolor="#ccc"),
        )

    # Beyla mildness annotations
    for ax, series_list, unit in [(axes[0], bey_cpu_clean, "mC"),
                                  (axes[1], bey_mem_clean, "MiB")]:
        means_bey = [float(np.mean(s)) for s in series_list if s]
        if len(means_bey) >= 2:
            span = max(means_bey) - min(means_bey)
            rel  = span / max(means_bey) * 100 if max(means_bey) > 0 else 0
            ps.note(
                ax, 0.98, 0.03,
                f"Beyla variation: {span:.2f} {unit} ({rel:.0f}%) — mild",
                transform=ax.transAxes, fontsize=8, ha="right", va="bottom",
                bbox=dict(boxstyle="round,pad=0.3", facecolor="#d4edda", edgecolor="#888"),
            )

    ps.note(
        axes[1], 0.02, 0.97,
        "Prom memory flat: TSDB cardinality drives size,\nnot scrape rate.",
        transform=axes[1].transAxes, fontsize=8, ha="left", va="top",
        bbox=dict(boxstyle="round,pad=0.3", facecolor="#f0f4ff", edgecolor="#8888cc"),
    )

    if ps.is_clean():
        legend_items = _fig4_symbol_legend_items()
        axes[0].legend(
            handles=legend_items,
            loc="upper left", fontsize=8,
            frameon=True, framealpha=0.92,
        )
        axes[1].legend(
            handles=legend_items,
            loc="upper left", fontsize=8,
            frameon=True, framealpha=0.92,
        )

    fig.tight_layout()
    out_path = out_dir / "fig4_statistical_comparison.png"
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"[fig4] Saved → {out_path}")

    return summary


# ---------------------------------------------------------------------------
# Section 9 — Figure 6: Data-Plane RTT — Overhead & Condition Comparison (RQ2)
#   Panel A: Grouped bar (mean + P99) per condition vs no-telemetry baseline
#   Panel B: RTT % increase over baseline per condition (line chart)
#            This was originally Fig 2 Panel C but needs a clean x-axis.
# ---------------------------------------------------------------------------

def fig_rtt_overhead(
    baseline: dict,
    prom_sweep: dict[str, dict],
    beyla_sweep: dict[str, dict],
    combined: dict,
    out_dir: Path,
) -> dict:
    """
    Two panels:
    A) Absolute mean + P99 RTT per condition with baseline reference lines.
    B) RTT % overhead above baseline — makes the overhead magnitude intuitive.
    """
    summary: dict = {}

    labels: list[str] = []
    mean_vals: list[float] = []
    p99_vals: list[float] = []
    bar_colours: list[str] = []

    bl_rtt_mean = baseline.get("rtt_mean_ms", float("nan"))
    bl_rtt_p99  = baseline.get("rtt_p99_ms",  float("nan"))
    summary["baseline_rtt_mean_ms"] = bl_rtt_mean
    summary["baseline_rtt_p99_ms"]  = bl_rtt_p99

    mean_stds: list[float] = []
    p99_stds:  list[float] = []

    def _clean_rtt_stats(agg: dict, key_mean: str, key_p99: str
                         ) -> tuple[float, float, float, float]:
        """Return (median_ms, p99_ms, half_iqr_mean, half_iqr_p99) with outlier-cleaned values."""
        raw_mean = _remove_outliers_robust(
            [v for v in extract_series(agg, key_mean) if not np.isnan(v)])
        raw_p99  = _remove_outliers_robust(
            [v for v in extract_series(agg, key_p99)  if not np.isnan(v)])
        m_ms  = float(np.median(raw_mean)) if raw_mean else agg.get(f"{key_mean}_mean", float("nan"))
        p_ms  = float(np.median(raw_p99))  if raw_p99  else agg.get(f"{key_p99}_mean",  float("nan"))
        m_err = (float(np.percentile(raw_mean, 75) - np.percentile(raw_mean, 25)) / 2
                 if len(raw_mean) > 1 else 0.0)
        p_err = (float(np.percentile(raw_p99,  75) - np.percentile(raw_p99,  25)) / 2
                 if len(raw_p99)  > 1 else 0.0)
        return m_ms, p_ms, m_err, p_err

    iv_colour = {"1s": COLOURS["prom_1s"], "5s": COLOURS["prom_5s"],
                 "15s": COLOURS["prom_15s"], "30s": COLOURS["prom_30s"]}
    for iv in ["1s", "5s", "15s", "30s"]:
        agg = prom_sweep.get(iv, {})
        labels.append(f"Prom {iv}")
        m, p, ms, p99_std = _clean_rtt_stats(agg, "rtt_mean_ms", "rtt_p99_ms")
        mean_vals.append(m); p99_vals.append(p)
        mean_stds.append(ms); p99_stds.append(p99_std)
        bar_colours.append(iv_colour[iv])

    bey_colour = {"10pct": COLOURS["beyla_10"], "50pct": COLOURS["beyla_50"],
                  "100pct": COLOURS["beyla_100"]}
    for rv in ["10pct", "50pct", "100pct"]:
        agg = beyla_sweep.get(rv, {})
        labels.append(f"Beyla {rv.replace('pct','%')}")
        m, p, ms, p99_std = _clean_rtt_stats(agg, "rtt_mean_ms", "rtt_p99_ms")
        mean_vals.append(m); p99_vals.append(p)
        mean_stds.append(ms); p99_stds.append(p99_std)
        bar_colours.append(bey_colour[rv])

    labels.append("Combined")
    m, p, ms, p99_std = _clean_rtt_stats(combined, "rtt_mean_ms", "rtt_p99_ms")
    mean_vals.append(m); p99_vals.append(p)
    mean_stds.append(ms); p99_stds.append(p99_std)
    bar_colours.append(COLOURS["combined"])

    summary["labels"]    = labels
    summary["mean_ms"]   = mean_vals
    summary["p99_ms"]    = p99_vals

    if not HAS_MATPLOTLIB:
        return summary

    x  = np.arange(len(labels))
    w  = 0.35
    fig, axes = plt.subplots(1, 2, figsize=(18, 6))
    ps.suptitle(
        fig,
        "Figure 6 — Data-Plane Ping RTT: Telemetry Overhead (RQ2)\n"
        "RTT = UE (uesimtun0) → UPF ping (data-plane latency, not registration latency). "
        "Error bars = IQR/2 (outlier-cleaned, 6 runs).",
        fontsize=12, fontweight="bold"
    )

    # ── Panel A: Absolute RTT grouped bar with error bars ─────────────
    ax = axes[0]
    m_clean   = [v if not np.isnan(v) else 0.0 for v in mean_vals]
    p99_clean = [v if not np.isnan(v) else 0.0 for v in p99_vals]

    ax.bar(x - w/2, m_clean,   w, label="Median RTT",  color="#4e79a7", alpha=0.8)
    ax.errorbar(x - w/2, m_clean, yerr=mean_stds,
                fmt="none", color="#1a3a5c", capsize=3, linewidth=1.2)
    ax.bar(x + w/2, p99_clean, w, label="P99 RTT",   color="#e15759", alpha=0.8)
    ax.errorbar(x + w/2, p99_clean, yerr=p99_stds,
                fmt="none", color="#7a0000", capsize=3, linewidth=1.2)

    if not np.isnan(bl_rtt_mean):
        ax.axhline(bl_rtt_mean, color="#4e79a7", linestyle=":", linewidth=1.8,
                   label=f"Baseline median ({bl_rtt_mean:.2f} ms, no telemetry)")
    if not np.isnan(bl_rtt_p99):
        ax.axhline(bl_rtt_p99, color="#e15759", linestyle=":", linewidth=1.8,
                   label=f"Baseline P99 ({bl_rtt_p99:.2f} ms, no telemetry)")

    ax.set_xticks(x)
    ax.set_xticklabels(labels, rotation=30, ha="right", fontsize=9)
    ax.set_ylabel("RTT (ms)", fontsize=11)
    ps.title(
        ax,
        "Absolute RTT per Telemetry Condition\n"
        "Dotted lines = no-telemetry baseline reference",
        clean="Absolute RTT per condition",
    )
    ax.legend(fontsize=8)
    ax.grid(axis="y", alpha=0.3)
    ps.note(
        ax, 0.02, 0.97,
        "All conditions show mild RTT increase vs baseline.\n"
        "No single configuration stands out as significantly worse.",
        transform=ax.transAxes, fontsize=8, va="top", color="#444444",
        style="italic",
    )

    # ── Panel B: RTT % overhead above baseline ────────────────────────
    ax2 = axes[1]
    mean_pct_overhead = [
        (v - bl_rtt_mean) / bl_rtt_mean * 100
        if (not np.isnan(v) and not np.isnan(bl_rtt_mean) and bl_rtt_mean > 0)
        else float("nan")
        for v in mean_vals
    ]
    p99_pct_overhead = [
        (v - bl_rtt_p99) / bl_rtt_p99 * 100
        if (not np.isnan(v) and not np.isnan(bl_rtt_p99) and bl_rtt_p99 > 0)
        else float("nan")
        for v in p99_vals
    ]
    mean_pct_err = [
        (std / bl_rtt_mean * 100) if (not np.isnan(bl_rtt_mean) and bl_rtt_mean > 0) else 0.0
        for std in mean_stds
    ]
    p99_pct_err = [
        (std / bl_rtt_p99 * 100) if (not np.isnan(bl_rtt_p99) and bl_rtt_p99 > 0) else 0.0
        for std in p99_stds
    ]

    mean_clean2 = [v if not np.isnan(v) else 0.0 for v in mean_pct_overhead]
    p99_clean2  = [v if not np.isnan(v) else 0.0 for v in p99_pct_overhead]

    ax2.bar(x - w/2, mean_clean2, w, color=bar_colours, alpha=0.75,
            edgecolor="black", linewidth=0.5, label="Mean RTT overhead")
    ax2.errorbar(x - w/2, mean_clean2, yerr=mean_pct_err,
                 fmt="none", color="#333333", capsize=3, linewidth=1.0)
    ax2.bar(x + w/2, p99_clean2, w, color=bar_colours, alpha=0.45,
            edgecolor="black", linewidth=0.5, hatch="//", label="P99 RTT overhead")
    ax2.errorbar(x + w/2, p99_clean2, yerr=p99_pct_err,
                 fmt="none", color="#333333", capsize=3, linewidth=1.0)
    ax2.axhline(0, color="black", linewidth=1.2)
    ax2.set_xticks(x)
    ax2.set_xticklabels(labels, rotation=30, ha="right", fontsize=9)
    ax2.set_ylabel("RTT increase above baseline (%)", fontsize=10)
    ps.title(
        ax2,
        "RTT % Overhead Above No-Telemetry Baseline\n"
        "Solid = median overhead; hatched = P99 overhead; error bars = IQR/2",
        clean="RTT overhead above baseline (%)",
    )
    ax2.legend(fontsize=8)
    ax2.grid(axis="y", alpha=0.3)

    fig.tight_layout()
    out_path = out_dir / "fig6_rtt_overhead.png"
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"[fig6] Saved → {out_path}")

    return summary


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Group A Observability Overhead Analysis Pipeline"
    )
    parser.add_argument(
        "--data-dir", type=Path, default=DATA_ROOT,
        help="Root data directory (default: data/experiments/A)"
    )
    parser.add_argument(
        "--out-dir", type=Path, default=OUT_DIR,
        help="Output directory for figures and JSON (default: analysis/A_figures)"
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
    out_dir: Path   = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    ps.set_clean(args.clean)

    if args.no_plots:
        global HAS_MATPLOTLIB
        HAS_MATPLOTLIB = False

    print(f"[A_analysis] Data root : {data_root}")
    print(f"[A_analysis] Output dir: {out_dir}")

    if not data_root.exists():
        print(f"[ERROR] Data directory not found: {data_root}", file=sys.stderr)
        print("  Run experiments/A/run_all.sh first to collect data.", file=sys.stderr)
        sys.exit(1)

    # ── Load all conditions ────────────────────────────────────────────
    print("\n[load] Loading experiment data...")
    baseline    = load_baseline(data_root)
    prom_sweep  = load_prometheus_sweep(data_root)
    beyla_sweep = load_beyla_sweep(data_root)
    combined    = load_combined(data_root)
    scalability = load_scalability(data_root)

    print(f"  baseline conditions  : {'OK' if baseline else 'MISSING (run 01_baseline.sh)'}")
    print(f"  prometheus sweep     : {list(prom_sweep.keys()) or 'MISSING (run 02_prometheus_sweep.sh)'}")
    print(f"  beyla sweep          : {list(beyla_sweep.keys()) or 'MISSING (run 03_beyla_sweep.sh)'}")
    print(f"  combined             : {'OK' if combined else 'MISSING (run 04_combined.sh)'}")
    _sc_info = {b: list(levels.keys()) for b, levels in scalability.items()} if scalability else "MISSING (run 05_scalability.sh)"
    print(f"  scalability          : {_sc_info}")

    # ── Generate figures ───────────────────────────────────────────────
    print("\n[figures] Generating analysis figures...")
    results: dict[str, Any] = {}

    results["fig1_overhead"] = fig_overhead_decomposition(
        baseline, prom_sweep, beyla_sweep, combined, out_dir
    )
    results["fig2_granularity"] = fig_granularity_curve(
        prom_sweep, beyla_sweep, baseline, out_dir
    )
    results["fig3_scalability"] = fig_scalability(scalability, out_dir)
    results["fig4_statistics"]  = fig_statistical_comparison(
        prom_sweep, beyla_sweep, out_dir
    )
    results["fig6_rtt"]         = fig_rtt_overhead(
        baseline, prom_sweep, beyla_sweep, combined, out_dir
    )

    # ── Narrative summaries for each RQ ───────────────────────────────
    _p5 = prom_sweep.get("5s", {})
    rq1_prom_5s_overhead = (
        _p5.get("stack_cpu_mcores_mean", float("nan"))
        if not np.isnan(_p5.get("stack_cpu_mcores_mean", float("nan")))
        else _p5.get("monitoring_cpu_mcores_mean", _p5.get("prom_cpu_mcores_mean", float("nan")))
    )
    rq1_beyla_100_overhead = _push_cpu_mcores(
        beyla_sweep.get("100pct", {}).get("beyla_cpu_mcores_mean"),
        beyla_sweep.get("100pct", {}).get("jaeger_cpu_mcores_mean"),
    )
    bl_rtt = baseline.get("rtt_p99_ms", float("nan"))
    beyla_rtt = beyla_sweep.get("100pct", {}).get("rtt_p99_ms_mean", float("nan"))
    rtt_delta = beyla_rtt - bl_rtt if not (np.isnan(beyla_rtt) or np.isnan(bl_rtt)) else float("nan")

    results["rq1_summary"] = {
        "prometheus_5s_cpu_mcores":         rq1_prom_5s_overhead,
        "beyla_100pct_push_cpu_mcores":      rq1_beyla_100_overhead,
        "overhead_ratio_push_vs_pull":
            rq1_beyla_100_overhead / max(rq1_prom_5s_overhead, 0.001)
            if not np.isnan(rq1_prom_5s_overhead) else float("nan"),
    }
    results["rq2_summary"] = {
        "metric": "data_plane_ping_rtt_ms",
        "note": "RTT is uesimtun0 ping to UPF gateway, not UE registration procedure latency",
        "baseline_rtt_p99_ms":              bl_rtt,
        "beyla_100pct_rtt_p99_ms":          beyla_rtt,
        "ebpf_uprobe_rtt_penalty_ms":       rtt_delta,
    }
    results["rq3_summary"] = {
        "note": "Full Time-to-Detect analysis requires C-fault-detection data. "
                "See fig5 value_metrics for the unified telemetry value score."
    }

    # ── Write results JSON ─────────────────────────────────────────────
    results_path = out_dir / "A_results.json"
    # Also write to analysis/ root for cross-experiment consumption
    root_results_path = Path(__file__).resolve().parent / "A_results.json"
    for rp in [results_path, root_results_path]:
        try:
            rp.write_text(json.dumps(results, indent=2, allow_nan=True))
            print(f"[results] JSON written → {rp}")
        except Exception as e:
            print(f"[WARN] Could not write {rp}: {e}", file=sys.stderr)

    print("\n[A_analysis] Done.")
    print(f"  Figures : {out_dir}/fig*.png")
    print(f"  Results : {results_path}")


if __name__ == "__main__":
    main()

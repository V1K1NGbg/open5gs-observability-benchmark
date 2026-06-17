# Open5GS Observability Benchmark

Reproducible benchmark suite for measuring **observability overhead** and **fault-detection fidelity** on a 5G SA core running [Open5GS](https://open5gs.org/) in Kubernetes.

The stack runs on a local [kind](https://kind.sigs.k8s.io/) cluster with UERANSIM for UE/gNB simulation, Chaos Mesh for fault injection, and Prometheus, Loki, Jaeger, and Grafana Beyla for telemetry collection.

## Experiment groups

| Group | Focus | Runtime (approx.) |
|-------|--------|-------------------|
| **A** - Observability overhead | Baseline (no telemetry), Prometheus scrape sweeps, Beyla sampling, combined production profile, UE scaling | ~6.5 h |
| **C** - Fault detection | 22 injected faults with pre/during/post telemetry (Prometheus, Jaeger, Loki, K8s events, NRF API, UE RTT) | ~17–21 h |

Group **B** (log strategies) is referenced by the top-level orchestrator but not included in this repository.

## Prerequisites

- Docker, [kind](https://kind.sigs.k8s.io/), kubectl, Helm 3
- Bash, Python 3 with `numpy`, `pandas`, `scipy`, `matplotlib`
- Sufficient host resources for a 3-node cluster (1 control-plane + 2 workers)

## Quick start

```bash
# Create cluster and deploy Open5GS, UERANSIM, observability stack, and Chaos Mesh
./cluster-start.sh

# Port-forward Grafana (admin / admin)
kubectl port-forward -n monitoring deployment/kube-prom-grafana 3000:3000
```

## Running experiments

Run inside a long-lived session (`tmux` / `screen` recommended):

```bash
# Group A — observability overhead
bash experiments/A/run_all.sh

# Group C — fault detection
bash experiments/C-fault-detection/run_all.sh

# All groups (A → B → C; B will fail if not present)
bash experiments/run_all_phases.sh
```

Each orchestrator supports `--from` and `--only` flags. Environment variables such as `COLLECTION_DURATION`, `UE_COUNT`, and fault phase durations (`PRE_DURATION`, `FAULT_DURATION`, `POST_DURATION`) override defaults.

Results are written to `data/experiments/`.

## Analysis

```bash
python3 analysis/A_analysis.py   # figures → analysis/A_figures/
python3 analysis/C_analysis.py   # figures → analysis/C_figures/
```

Set `RUN_ANALYSIS=1` when running Group A to regenerate figures automatically.

## Repository layout

```
cluster-start.sh          # kind cluster + full stack deployment
kind/                     # cluster config, Helm values, chaos manifests, Beyla
experiments/
  A/                      # observability overhead experiments
  C-fault-detection/      # fault injection experiments
  lib/                    # shared collectors, hooks, and helpers
analysis/                 # post-processing scripts and figure output
```

## Authors

Victor Ilchev, Boyan Bonev, David Ghergut, Stoyan Kucarov, Yana Mihaylova

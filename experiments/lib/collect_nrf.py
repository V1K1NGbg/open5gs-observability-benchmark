#!/usr/bin/env python3
"""
experiments/lib/collect_nrf.py

Snapshot the current registered NF instances per NF-type via the NRF HTTP API
(reached by kubectl exec into the NRF pod). Drops to 0 during NRF kill,
useful for confirming dependency-failure-nrf and for measuring propagation.

Usage:
    python3 collect_nrf.py \
        --namespace open5gs \
        --out /path/to/output/dir
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

NF_TYPES = ["AMF", "AUSF", "UDM", "UDR", "SMF", "PCF", "NSSF", "SCP"]


def kubectl(args: list, timeout: int = 10) -> str:
    return subprocess.check_output(args, timeout=timeout, text=True).strip()


def snapshot(namespace: str) -> dict:
    result = {}
    try:
        nrf_ip = kubectl([
            "kubectl", "get", "pod", "-n", namespace,
            "-l", "app.kubernetes.io/name=nrf",
            "-o", "jsonpath={.items[0].status.podIP}",
        ])
        nrf_pod = kubectl([
            "kubectl", "get", "pod", "-n", namespace,
            "-l", "app.kubernetes.io/name=nrf",
            "-o", "jsonpath={.items[0].metadata.name}",
        ])
    except Exception as e:
        result["error"] = f"NRF pod lookup failed: {e}"
        return result

    if not nrf_ip or not nrf_pod:
        result["error"] = "NRF pod not found (likely killed)"
        return result

    for nf in NF_TYPES:
        try:
            raw = kubectl([
                "kubectl", "exec", "-n", namespace, nrf_pod, "-c", "open5gs-nrf",
                "--", "curl", "-s", "--http2-prior-knowledge",
                f"http://{nrf_ip}:7777/nnrf-nfm/v1/nf-instances?nf-type={nf}",
            ])
            d = json.loads(raw) if raw else {}
            count = len(d.get("_links", {}).get("items", []))
            result[nf] = count
        except Exception:
            result[nf] = -1
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--namespace", default="open5gs")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    result = snapshot(args.namespace)
    (out_dir / "nrf_registrations.json").write_text(json.dumps(result, indent=2))
    print(f"  [nrf] nrf_registrations.json: {result}")


if __name__ == "__main__":
    main()

#!/usr/bin/env bash
# experiments/lib/provision_ues.sh
#
# Provision N subscribers into Open5GS MongoDB via kubectl exec.
# Uses mongosh upsert so it's idempotent.
#
# Usage: bash provision_ues.sh <count>
#   e.g. bash provision_ues.sh 50

set -euo pipefail

COUNT="${1:-50}"
NAMESPACE="open5gs"

# Find the MongoDB pod
MONGO_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=mongodb \
    --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)

if [[ -z "$MONGO_POD" ]]; then
    # Fallback: search by name prefix
    MONGO_POD=$(kubectl get pods -n "$NAMESPACE" --no-headers \
        | awk '/mongodb/{print $1}' | head -1)
fi

if [[ -z "$MONGO_POD" ]]; then
    echo "[provision] ERROR: Could not find MongoDB pod in namespace $NAMESPACE" >&2
    exit 1
fi

echo "[provision] Using MongoDB pod: $MONGO_POD"
echo "[provision] Provisioning $COUNT subscribers..."

# Build the mongosh script
MONGO_SCRIPT=$(python3 - <<PYEOF
count = $COUNT
lines = []
for i in range(1, count + 1):
    imsi = f"999700000{i:06d}"
    lines.append(f"""
db.getSiblingDB("open5gs").subscribers.updateOne(
  {{ imsi: "{imsi}" }},
  {{ \$set: {{
    imsi: "{imsi}",
    msisdn: [],
    imeisv: "4301816125816151",
    mme_host: [],
    mme_realm: [],
    purge_flag: [],
    security: {{
      k: "465B5CE8B199B49FAA5F0A2EE238A6BC",
      op: null,
      opc: "E8ED289DEBA952E4283B54E88E6183CA",
      amf: "8000",
      sqn: NumberLong(1)
    }},
    ambr: {{ downlink: {{ value: 1, unit: 3 }}, uplink: {{ value: 1, unit: 3 }} }},
    slice: [{{
      sst: 1,
      sd: "111111",
      default_indicator: true,
      session: [{{
        name: "internet",
        type: 3,
        qos: {{ index: 9, arp: {{ priority_level: 8, pre_emption_capability: 1, pre_emption_vulnerability: 1 }} }},
        ambr: {{ downlink: {{ value: 1, unit: 3 }}, uplink: {{ value: 1, unit: 3 }} }},
        ue: {{ addr: "0.0.0.0" }},
        pcc_rule: []
      }}]
    }}],
    access_restriction_data: 32,
    subscriber_status: 0,
    network_access_mode: 0,
    subscribed_rau_tau_timer: 12,
    __v: 0
  }} }},
  {{ upsert: true }}
);""")
print("\n".join(lines))
print(f'print("Provisioned $COUNT subscribers.");')
PYEOF
)

# Write script to a temp file inside the pod to avoid ARG_MAX limits
TMPFILE=$(kubectl exec -n "$NAMESPACE" "$MONGO_POD" -- mktemp /tmp/provision_XXXXXX.js 2>/dev/null)
echo "$MONGO_SCRIPT" | kubectl exec -i -n "$NAMESPACE" "$MONGO_POD" -- \
    sh -c "cat > $TMPFILE"
kubectl exec -n "$NAMESPACE" "$MONGO_POD" -- \
    mongosh --quiet "mongodb://localhost/open5gs" "$TMPFILE"
kubectl exec -n "$NAMESPACE" "$MONGO_POD" -- rm -f "$TMPFILE" 2>/dev/null || true

echo "[provision] Done. $COUNT subscribers available."
echo "[provision] Verify with:"
echo "  kubectl exec -n $NAMESPACE $MONGO_POD -- mongosh --quiet --eval 'db.getSiblingDB(\"open5gs\").subscribers.countDocuments()' open5gs"

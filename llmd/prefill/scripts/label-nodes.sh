#!/bin/bash
# Label worker nodes for P/D disaggregation.
# Uses only nodeSelector (no taints) to avoid disrupting system DaemonSets.

set -euo pipefail

WORKERS=$(oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/master' -o name)
WORKER_COUNT=$(echo "$WORKERS" | wc -l | tr -d ' ')

if [ "$WORKER_COUNT" -lt 2 ]; then
  echo "ERROR: Need at least 2 dedicated worker nodes, found $WORKER_COUNT"
  exit 1
fi

WORKER_1=$(echo "$WORKERS" | sed -n '1p' | sed 's|node/||')
WORKER_2=$(echo "$WORKERS" | sed -n '2p' | sed 's|node/||')

echo "Labeling $WORKER_1 as prefill..."
oc label node "$WORKER_1" llm-d.ai/role=prefill --overwrite

echo "Labeling $WORKER_2 as decode..."
oc label node "$WORKER_2" llm-d.ai/role=decode --overwrite

echo ""
echo "Verification:"
oc get nodes -L llm-d.ai/role

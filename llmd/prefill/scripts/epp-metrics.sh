#!/bin/bash
# Query EPP Metrics

set -euo pipefail

echo "=== Querying EPP Metrics ==="

# get the pod IP of EPP
EPP_IP=$(oc get pod -n llm-d-lab -l app=llm-d-sim-epp \
  -o jsonpath='{.items[0].status.podIP}')

# Query the metrics port 9090
oc exec helper -n llm-d-lab -- \
  curl -s "http://${EPP_IP}:9090/metrics" 2>/dev/null \
  | grep 'disagg_decision_total' | grep -v '^#'
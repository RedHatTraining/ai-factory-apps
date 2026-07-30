#!/bin/bash
# Query Prefill/Decode Pod Metrics

set -euo pipefail

echo ""
echo "=== Querying Prefill and Decode Pod Metrics ==="
echo ""

PREFILL_IP=$(oc get pod -n llm-d-lab -l llm-d.ai/role=prefill \
  -o jsonpath='{.items[0].status.podIP}')
  
DECODE_IP=$(oc get pod -n llm-d-lab -l llm-d.ai/role=decode \
  -o jsonpath='{.items[0].status.podIP}')

echo "=== Prefill pod metrics ==="
oc exec helper -n llm-d-lab -- \
  curl -s "http://${PREFILL_IP}:8000/metrics" 2>/dev/null \
  | grep 'request_success_total' | grep -v '^#'

echo ""
echo "=== Decode pod metrics ==="
oc exec helper -n llm-d-lab -- \
  curl -s "http://${DECODE_IP}:8200/metrics" 2>/dev/null \
  | grep 'request_success_total' | grep -v '^#'
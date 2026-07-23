#!/bin/bash
#
# inject-metrics.sh — Inject fake metrics on simulator pods
#
# Usage:
#   bash scripts/inject-metrics.sh                     # Inject differential metrics
#   bash scripts/inject-metrics.sh --reset              # Reset all pods to idle
#
# Without --reset:
#   Pod 0: kv-cache-usage=0.80  (penalized by kv-cache-utilization-scorer)
#   Pod 1: waiting-requests=8   (penalized by queue-scorer)
#   Pod 2: idle                 (should win all requests)
#
set -euo pipefail

NAMESPACE="llm-d-lab"
RESET=false

if [[ "${1:-}" == "--reset" ]]; then
  RESET=true
fi

IPS=($(oc get pods -n "${NAMESPACE}" -l app=llm-d-sim \
  -o jsonpath='{.items[*].status.podIP}'))
PODS=($(oc get pods -n "${NAMESPACE}" -l app=llm-d-sim \
  -o jsonpath='{.items[*].metadata.name}'))

if [ "${#IPS[@]}" -lt 3 ]; then
  echo "ERROR: Expected 3 simulator pods, found ${#IPS[@]}."
  exit 1
fi

inject() {
  local ip=$1 payload=$2
  oc exec deploy/llm-d-sim-epp -n "${NAMESPACE}" -- \
    curl -s -X POST "http://${ip}:8000/admin/config" \
    -H "Content-Type: application/json" \
    -d "${payload}" 2>/dev/null > /dev/null
}

suffix() {
  echo "${1##*-}"
}

if [ "${RESET}" = true ]; then
  echo "Resetting all pods to idle..."
  for i in 0 1 2; do
    inject "${IPS[$i]}" '{"fake-metrics":{"kv-cache-usage":0,"waiting-requests":0}}'
    echo "  ${PODS[$i]}: reset"
  done
  echo ""
  echo "All pods reset to idle."
else
  echo "Injecting differential metrics..."
  echo ""

  inject "${IPS[0]}" '{"fake-metrics":{"kv-cache-usage":0.80,"waiting-requests":0}}'
  echo "  ${PODS[0]}: kv-cache-usage=0.80"

  inject "${IPS[1]}" '{"fake-metrics":{"waiting-requests":8,"kv-cache-usage":0}}'
  echo "  ${PODS[1]}: waiting-requests=8"

  echo "  ${PODS[2]}: idle (no fake metrics)"

  echo ""
  echo "Waiting for EPP to pick up new metrics..."
  sleep 3
  echo "Ready. The idle pod ($(suffix "${PODS[2]}")) should win all requests."
fi

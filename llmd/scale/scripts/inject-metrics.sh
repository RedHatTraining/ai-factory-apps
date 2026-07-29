#!/bin/bash
#
# inject-metrics.sh — Inject fake metrics on simulator pods
#
# Usage:
#   bash scripts/inject-metrics.sh                  # Inject differential metrics
#   bash scripts/inject-metrics.sh --reset           # Reset all pods to idle
#   bash scripts/inject-metrics.sh --scale-up        # All pods: kv-cache-usage=0.95
#   bash scripts/inject-metrics.sh --saturate-one    # Pod 0: waiting-requests=10
#   bash scripts/inject-metrics.sh --saturate-all    # All pods: waiting-requests=10
#
set -euo pipefail

NAMESPACE="llm-d-lab"
MODE="differential"

case "${1:-}" in
  --reset)        MODE="reset" ;;
  --scale-up)     MODE="scale-up" ;;
  --saturate-one) MODE="saturate-one" ;;
  --saturate-all) MODE="saturate-all" ;;
  "")             MODE="differential" ;;
  *) echo "Usage: $0 [--reset|--scale-up|--saturate-one|--saturate-all]" >&2; exit 1 ;;
esac

IPS=($(oc get pods -n "${NAMESPACE}" -l app=llm-d-sim \
  -o jsonpath='{.items[*].status.podIP}'))
PODS=($(oc get pods -n "${NAMESPACE}" -l app=llm-d-sim \
  -o jsonpath='{.items[*].metadata.name}'))

if [ "${#IPS[@]}" -lt 3 ]; then
  echo "ERROR: Expected at least 3 simulator pods, found ${#IPS[@]}."
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

case "${MODE}" in
  reset)
    echo "Resetting all pods to idle..."
    for i in $(seq 0 $(( ${#IPS[@]} - 1 ))); do
      inject "${IPS[$i]}" '{"fake-metrics":{"kv-cache-usage":0,"waiting-requests":0}}'
      echo "  ${PODS[$i]}: reset"
    done
    echo ""
    echo "All pods reset to idle."
    ;;

  scale-up)
    echo "Injecting high KV cache on all pods..."
    echo ""
    for i in $(seq 0 $(( ${#IPS[@]} - 1 ))); do
      inject "${IPS[$i]}" '{"fake-metrics":{"kv-cache-usage":0.95,"waiting-requests":0}}'
      echo "  ${PODS[$i]}: kv-cache-usage=0.95"
    done
    echo ""
    echo "Waiting for metrics to propagate..."
    sleep 3
    echo "All pods set to kv-cache-usage=0.95 (above 0.8 threshold)."
    ;;

  saturate-one)
    echo "Saturating one pod..."
    echo ""
    inject "${IPS[0]}" '{"fake-metrics":{"waiting-requests":10,"kv-cache-usage":0}}'
    echo "  ${PODS[0]}: waiting-requests=10 (saturated)"
    echo "  ${PODS[1]}: idle"
    echo "  ${PODS[2]}: idle"
    echo ""
    echo "Waiting for EPP to pick up new metrics..."
    sleep 3
    echo "Pod $(suffix "${PODS[0]}") is saturated. The other two should receive all traffic."
    ;;

  saturate-all)
    echo "Saturating all pods..."
    echo ""
    for i in 0 1 2; do
      inject "${IPS[$i]}" '{"fake-metrics":{"waiting-requests":10,"kv-cache-usage":0}}'
      echo "  ${PODS[$i]}: waiting-requests=10 (saturated)"
    done
    echo ""
    echo "Waiting for EPP to pick up new metrics..."
    sleep 3
    echo "All pods saturated. Requests should still succeed (graceful degradation)."
    ;;

  differential)
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
    ;;
esac

#!/bin/bash
#
# watch-scaling.sh — Watch the full scale-up cycle
#
# Three phases:
#   1. Wait for ScaledObject to become Active (metric above threshold)
#   2. Poll until the HPA adds a replica
#   3. Wait for the new pod to become Ready
#
set -euo pipefail

NAMESPACE="llm-d-lab"
MAX_ITERATIONS=12
INTERVAL=15

START_REPLICAS=$(oc get deploy llm-d-sim -n "${NAMESPACE}" \
  -o jsonpath='{.spec.replicas}')

echo "Watching for scale-up event (checking every ${INTERVAL}s)..."
echo "Starting replicas: ${START_REPLICAS}"
echo ""

PHASE="waiting-for-active"

for i in $(seq 1 "${MAX_ITERATIONS}"); do
  sleep "${INTERVAL}"

  REPLICAS=$(oc get deploy llm-d-sim -n "${NAMESPACE}" \
    -o jsonpath='{.spec.replicas}')

  HPA_TARGET=$(oc get hpa -n "${NAMESPACE}" keda-hpa-llm-d-sim-keda \
    -o jsonpath='{.status.currentMetrics[0].external.current.value}' \
    2>/dev/null || echo "?")

  SO_ACTIVE=$(oc get scaledobject llm-d-sim-keda -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' \
    2>/dev/null || echo "?")

  ACTIVE_LABEL="$([ "${SO_ACTIVE}" = "True" ] && echo "Active" || echo "Inactive")"

  printf "  [%s] replicas=%-3s  hpa=%s/800m  scaledobject=%s\n" \
    "$(date +%H:%M:%S)" "${REPLICAS}" "${HPA_TARGET}" "${ACTIVE_LABEL}"

  if [[ "${PHASE}" == "waiting-for-active" && "${SO_ACTIVE}" == "True" ]]; then
    echo ""
    echo "ScaledObject is Active — metric exceeds threshold."
    echo "Waiting for HPA to add a replica (stabilization window)..."
    echo ""
    PHASE="waiting-for-scaleup"
  fi

  if [[ "${PHASE}" != "waiting-for-active" && "${REPLICAS}" -gt "${START_REPLICAS}" ]]; then
    echo ""
    echo "SCALE-UP DETECTED! Replicas: ${START_REPLICAS} → ${REPLICAS}"
    echo ""
    echo "Waiting for the new pod to become Ready..."
    oc wait --for=condition=Ready pod -l app=llm-d-sim \
      -n "${NAMESPACE}" --timeout=180s
    echo ""
    echo "All ${REPLICAS} pods are Ready."
    echo ""
    echo "Pods:"
    oc get pods -n "${NAMESPACE}" -l app=llm-d-sim --no-headers
    exit 0
  fi
done

echo ""
echo "No scale-up detected after ${MAX_ITERATIONS} checks."
echo "The stabilization window may still be in progress."
echo "Run this script again or check manually: oc get deploy llm-d-sim -n ${NAMESPACE}"

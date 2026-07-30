#!/bin/bash
#
# setup-scaling.sh — Set up the autoscaling configuration
#
# Applies the PrometheusRule (metric aliasing), KEDA authentication chain,
# VariantAutoscaling CR, and KEDA ScaledObject.
#
# Requires the Gateway to be configured (complete the cache exercise first).
#
# In production, LLMInferenceService creates these resources from spec.scaling.
# The KEDA auth chain is a one-time cluster setup by the platform team.
#
set -euo pipefail

NAMESPACE="llm-d-lab"
YAML_DIR="$(cd "$(dirname "$0")/../yaml" && pwd)"

###############################################################################
# Step 0: Verify Gateway exists
###############################################################################

echo "Checking gateway status..."

GW_EXISTS=$(oc get gateway llm-d-lab-gateway -n "${NAMESPACE}" \
  --no-headers 2>/dev/null | wc -l || echo "0")

if [ "${GW_EXISTS}" -eq 0 ]; then
  echo "ERROR: Gateway not found in namespace ${NAMESPACE}."
  echo "Complete the cache exercise first to set up the networking layer."
  exit 1
fi

ROUTE_URL=$(oc get route llm-d-lab-gateway -n "${NAMESPACE}" \
  -o jsonpath='{.status.ingress[0].host}' 2>/dev/null)
echo "  Gateway exists."
echo "  Route: ${ROUTE_URL}"
echo ""

###############################################################################
# Step 1: Metrics recording rules (PrometheusRule)
###############################################################################

echo "Setting up metrics recording rules..."
oc apply -f "${YAML_DIR}/prometheus-rule.yaml" -n "${NAMESPACE}"

THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring \
  -o jsonpath='{.spec.host}' 2>/dev/null)
TOKEN=$(oc whoami -t)

echo "  Waiting for recording rules to propagate (up to 60s)..."
for i in $(seq 1 12); do
  COUNT=$(curl -sk -G -H "Authorization: Bearer ${TOKEN}" \
    "https://${THANOS_HOST}/api/v1/query" \
    --data-urlencode 'query=kserve_vllm:kv_cache_usage_perc{namespace="llm-d-lab"}' \
    2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',{}).get('result',[])))" 2>/dev/null || echo "0")
  if [ "${COUNT}" -gt 0 ]; then
    echo "  Recording rules active — ${COUNT} time series found."
    break
  fi
  if [ "${i}" -eq 12 ]; then
    echo "  WARNING: Recording rules not yet visible. They may take a few more seconds."
  fi
  sleep 5
done
echo ""

###############################################################################
# Step 2: KEDA authentication chain
###############################################################################

echo "Setting up KEDA authentication..."
oc apply -f "${YAML_DIR}/keda-auth.yaml"

TOKEN_CHECK=$(oc get secret -n openshift-keda keda-metrics-reader-token \
  -o jsonpath='{.data.token}' 2>/dev/null || echo "")
if [ -n "${TOKEN_CHECK}" ]; then
  echo "  Token verified."
else
  echo "  Waiting for token to be populated..."
  sleep 5
  TOKEN_CHECK=$(oc get secret -n openshift-keda keda-metrics-reader-token \
    -o jsonpath='{.data.token}' 2>/dev/null || echo "")
  if [ -n "${TOKEN_CHECK}" ]; then
    echo "  Token verified."
  else
    echo "  WARNING: Token not yet populated. The ScaledObject may take longer to become ready."
  fi
fi
echo ""

###############################################################################
# Step 3: VariantAutoscaling CR
###############################################################################

echo "Creating VariantAutoscaling..."
oc apply -f "${YAML_DIR}/variant-autoscaling.yaml" -n "${NAMESPACE}"
echo ""

###############################################################################
# Step 4: KEDA ScaledObject
###############################################################################

echo "Creating ScaledObject..."
oc apply -f "${YAML_DIR}/keda-scaledobject.yaml" -n "${NAMESPACE}"

echo "  Waiting for ScaledObject to become ready (up to 90s)..."
for i in $(seq 1 18); do
  READY=$(oc get scaledobject llm-d-sim-keda -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [ "${READY}" = "True" ]; then
    echo "  ScaledObject READY=True"
    break
  fi
  if [ "${i}" -eq 18 ]; then
    echo "  WARNING: ScaledObject not ready yet. Check: oc describe scaledobject -n ${NAMESPACE}"
  fi
  sleep 5
done
echo ""

###############################################################################
# Summary
###############################################################################

echo "Autoscaling configuration ready."

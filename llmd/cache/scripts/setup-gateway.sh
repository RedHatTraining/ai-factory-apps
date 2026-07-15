#!/bin/bash
#
# setup-gateway.sh — Set up the networking layer for inference routing
#
# Creates the Gateway, ext_proc integration, HTTPRoute, and external Route
# that connect external clients to the llm-d inference pipeline.
#
# In production, LLMInferenceService creates these resources automatically.
# In the lab, you apply them manually because the simulator does not use
# the LLMInferenceService CR.
#
set -euo pipefail

NAMESPACE="llm-d-lab"
YAML_DIR="$(cd "$(dirname "$0")/../yaml" && pwd)"

echo "Applying Gateway configuration..."
oc apply -f "${YAML_DIR}/gateway-config.yaml" -n "${NAMESPACE}"
oc apply -f "${YAML_DIR}/gateway.yaml" -n "${NAMESPACE}"

echo "Waiting for Gateway to be programmed..."
oc wait gateway llm-d-lab-gateway -n "${NAMESPACE}" \
  --for=condition=Programmed --timeout=120s

echo ""
echo "Configuring ext_proc (EPP integration)..."
oc apply -f "${YAML_DIR}/destinationrule-epp.yaml" -n "${NAMESPACE}"
oc apply -f "${YAML_DIR}/envoyfilter-extproc.yaml" -n "${NAMESPACE}"

echo ""
echo "Creating HTTPRoute and external Route..."
oc apply -f "${YAML_DIR}/httproute.yaml" -n "${NAMESPACE}"
oc apply -f "${YAML_DIR}/route-external.yaml" -n "${NAMESPACE}"

echo ""
echo "Waiting for HTTPRoute to be accepted..."
sleep 5
STATUS=$(oc get httproute llm-d-sim-route -n "${NAMESPACE}" \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "Unknown")
echo "HTTPRoute Accepted: ${STATUS}"

echo ""
ROUTE_URL=$(oc get route llm-d-lab-gateway -n "${NAMESPACE}" \
  -o jsonpath='{.status.ingress[0].host}' 2>/dev/null || echo "")
if [ -n "${ROUTE_URL}" ]; then
  echo "Gateway URL: ${ROUTE_URL}"
  echo ""
  echo "Export it with:"
  echo "  export ROUTE_URL=${ROUTE_URL}"
else
  echo "WARNING: Route URL not available yet. Check with:"
  echo "  oc get route llm-d-lab-gateway -n ${NAMESPACE}"
fi

echo ""
echo "Networking setup complete."

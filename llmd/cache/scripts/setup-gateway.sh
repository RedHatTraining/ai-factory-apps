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
INGRESS_NS="openshift-ingress"
YAML_DIR="$(cd "$(dirname "$0")/../yaml" && pwd)"
ISTIO_TARGET_VERSION="v1.30.1"

###############################################################################
# Step 0: Verify Istio is healthy (patch version if needed)
###############################################################################

echo "Checking Istio gateway status..."

ISTIO_STATE=$(oc get istio openshift-gateway -n "${INGRESS_NS}" \
  -o jsonpath='{.status.state}' 2>/dev/null || echo "Unknown")

istiod_count() {
  oc get pods -n "${INGRESS_NS}" -l app=istiod \
    --no-headers 2>/dev/null | grep -c Running 2>/dev/null || true
}

if [ "${ISTIO_STATE}" = "Healthy" ]; then
  echo "  Istio CR is Healthy."
else
  ISTIOD_RUNNING=$(istiod_count)

  if [ "${ISTIOD_RUNNING:-0}" -eq 0 ]; then
    echo "  Istio CR state: ${ISTIO_STATE} — istiod not running."
    echo "  Patching Istio version to ${ISTIO_TARGET_VERSION}..."
    oc patch istio openshift-gateway -n "${INGRESS_NS}" \
      --type merge -p "{\"spec\":{\"version\":\"${ISTIO_TARGET_VERSION}\"}}" 2>/dev/null || true

    echo "  Waiting for istiod pod (up to 90s)..."
    for i in $(seq 1 18); do
      ISTIOD_RUNNING=$(istiod_count)
      if [ "${ISTIOD_RUNNING:-0}" -gt 0 ]; then
        break
      fi
      sleep 5
    done

    if [ "${ISTIOD_RUNNING:-0}" -gt 0 ]; then
      echo "  istiod is running."
    else
      echo "  ERROR: istiod did not start. Check: oc get pods -n ${INGRESS_NS} -l app=istiod"
      exit 1
    fi
  else
    echo "  Istio CR state: ${ISTIO_STATE} (istiod is running — continuing)."
  fi
fi

REV_VERSION=$(oc get istiorevision -A --no-headers \
  -o custom-columns='VERSION:.spec.version' 2>/dev/null | head -1 || echo "unknown")
echo "  IstioRevision version: ${REV_VERSION}"
echo ""

###############################################################################
# Step 1: Gateway, ext_proc, HTTPRoute, Route
###############################################################################

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
echo "Networking setup complete."

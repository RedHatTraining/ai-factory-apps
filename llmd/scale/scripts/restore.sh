#!/bin/bash
#
# restore.sh — Remove all scaling and flow control resources
#
# Removes the PrometheusRule, VariantAutoscaling, ScaledObject, HPAs,
# InferenceObjectives, KEDA auth chain, restores the EPP to baseline,
# and scales the simulator back to 3 replicas.
#
# Does NOT remove Gateway, EnvoyFilter, or HTTPRoute resources.
#
set -euo pipefail

NAMESPACE="llm-d-lab"

echo "Removing scaling resources..."
oc delete prometheusrule -n "${NAMESPACE}" vllm-metrics-alias --ignore-not-found 2>/dev/null
oc delete va -n "${NAMESPACE}" llm-d-sim-va --ignore-not-found 2>/dev/null
oc delete scaledobject -n "${NAMESPACE}" llm-d-sim-keda --ignore-not-found 2>/dev/null
oc delete hpa -n "${NAMESPACE}" --all --ignore-not-found 2>/dev/null
echo "  Scaling resources removed."
echo ""

echo "Removing InferenceObjectives..."
oc delete inferenceobjective -n "${NAMESPACE}" critical standard batch \
  --ignore-not-found 2>/dev/null || true
echo "  InferenceObjectives removed."
echo ""

echo "Removing KEDA auth resources..."
oc delete clustertriggerauthentication ai-inference-keda-thanos --ignore-not-found 2>/dev/null || true
oc delete secret -n openshift-keda keda-metrics-reader-token --ignore-not-found 2>/dev/null || true
oc delete clusterrolebinding keda-metrics-reader-monitoring --ignore-not-found 2>/dev/null || true
oc delete sa -n openshift-keda keda-metrics-reader --ignore-not-found 2>/dev/null || true
echo "  KEDA auth resources removed."
echo ""

echo "Resetting fake metrics on all pods..."
EPP_POD=$(oc get pods -n "${NAMESPACE}" -l app=llm-d-sim-epp --no-headers \
  -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
IPS=($(oc get pods -n "${NAMESPACE}" -l app=llm-d-sim --no-headers \
  -o custom-columns=IP:.status.podIP 2>/dev/null))
for IP in "${IPS[@]}"; do
  oc exec "${EPP_POD}" -n "${NAMESPACE}" -- \
    curl -s -X POST "http://${IP}:8000/admin/config" \
    -H "Content-Type: application/json" \
    -d '{"fake-metrics":{"kv-cache-usage":0,"waiting-requests":0,"running-requests":0}}' \
    > /dev/null 2>&1 || true
done
echo "  Fake metrics reset."
echo ""

echo "Restoring EPP configuration..."
oc apply -n "${NAMESPACE}" -f - <<'EPPEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: llm-d-sim-plugins
  namespace: llm-d-lab
data:
  default-plugins.yaml: |
    apiVersion: inference.networking.x-k8s.io/v1alpha1
    kind: EndpointPickerConfig
    plugins:
      - type: queue-scorer
      - type: kv-cache-utilization-scorer
    schedulingProfiles:
      - name: default
        plugins:
          - pluginRef: queue-scorer
            weight: 2
          - pluginRef: kv-cache-utilization-scorer
            weight: 2
EPPEOF
echo ""

echo "Restarting EPP..."
oc delete pod -n "${NAMESPACE}" -l app=llm-d-sim-epp 2>/dev/null
echo ""

echo "Scaling simulator to 3 replicas..."
oc scale deployment -n "${NAMESPACE}" llm-d-sim --replicas=3
echo ""

echo "Waiting for pods..."
oc wait -n "${NAMESPACE}" deployment/llm-d-sim \
  --for=condition=Available --timeout=120s
oc wait -n "${NAMESPACE}" deployment/llm-d-sim-epp \
  --for=condition=Available --timeout=60s
echo ""

echo "Verifying EPP configuration..."
oc logs deploy/llm-d-sim-epp -n "${NAMESPACE}" --tail=5 2>/dev/null \
  | grep -o '"config":".*"' | head -1 || true
echo ""

echo "Verifying end-to-end routing..."
ROUTE_URL=$(oc get route llm-d-lab-gateway -n "${NAMESPACE}" \
  -o jsonpath='{.status.ingress[0].host}' 2>/dev/null)
RESPONSE=$(curl -sk "https://${ROUTE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"test"}],"max_tokens":5}' 2>/dev/null)
MODEL=$(echo "${RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('model','ERROR'))" 2>/dev/null || echo "ERROR")
echo "Response: model=${MODEL}"
echo ""

echo "Restore complete. Simulator and EPP are back to baseline."

#!/bin/bash
#
# restore.sh — Restore simulator and EPP to baseline configuration
#
# Removes prefix caching from the simulator and restores the EPP
# to the default queue-scorer + kv-cache-utilization-scorer config.
# Cleans up the curl-helper pod.
#
set -euo pipefail

NAMESPACE="llm-d-lab"

echo "Deleting helper pod (if it exists)..."
oc delete pod curl-helper -n "${NAMESPACE}" \
  --ignore-not-found --force --grace-period=0 2>/dev/null || true

echo ""
echo "Restoring simulator configuration..."
oc patch deployment llm-d-sim -n "${NAMESPACE}" --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/args","value":[
    "--port=8000",
    "--model=Qwen/Qwen2.5-0.5B-Instruct",
    "--render-url=http://localhost:8082",
    "--mode=random",
    "--time-to-first-token=500ms",
    "--inter-token-latency=50ms",
    "--dataset-path=/data/sharegpt-500.sqlite3",
    "--dataset-in-memory",
    "--fake-metrics={\"kv-cache-usage\":0,\"running-requests\":0,\"waiting-requests\":0}"
  ]}
]'

echo "Waiting for rollout..."
oc rollout status deployment/llm-d-sim -n "${NAMESPACE}" --timeout=600s

echo ""
echo "Restoring EPP configuration..."
oc create configmap llm-d-sim-plugins -n "${NAMESPACE}" \
  --from-literal=default-plugins.yaml='apiVersion: inference.networking.x-k8s.io/v1alpha1
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
        weight: 2' \
  --dry-run=client -o yaml | oc apply -f -

echo ""
echo "Restarting EPP..."
oc delete pod -l app=llm-d-sim-epp -n "${NAMESPACE}"
oc wait --for=condition=Ready pod -l app=llm-d-sim-epp \
  -n "${NAMESPACE}" --timeout=60s

echo ""
echo "Verifying EPP configuration..."
oc logs deploy/llm-d-sim-epp -n "${NAMESPACE}" 2>/dev/null \
  | grep 'Loaded raw configuration' | tail -1

echo ""
echo "Verifying end-to-end routing..."
ROUTE_URL=$(oc get route llm-d-lab-gateway -n "${NAMESPACE}" \
  -o jsonpath='{.status.ingress[0].host}')
curl -sk "https://${ROUTE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":5}' \
  | python3 -c "import sys,json; r=json.load(sys.stdin); \
    print(f'Response: model={r[\"model\"]}, tokens={r[\"usage\"][\"total_tokens\"]}')"

echo ""
echo "Restore complete. Simulator and EPP are back to baseline."

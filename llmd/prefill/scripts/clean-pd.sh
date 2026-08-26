#!/bin/bash
# Restore cluster to original state: remove P/D deployments,
# scale up uniform simulator, restore original EPP config.

set -euo pipefail

echo "=== Cleaning up exercise resources ==="

echo "Removing P/D deployments and services..."
oc delete deployment -n llm-d-lab llm-d-sim-prefill llm-d-sim-decode --ignore-not-found
oc delete service -n llm-d-lab llm-d-sim-prefill llm-d-sim-decode --ignore-not-found

echo "Removing node labels..."
for node in $(oc get nodes -l llm-d.ai/role -o name 2>/dev/null); do
  oc label "$node" llm-d.ai/role- || true
done

echo "Deleting helper pods..."
oc delete pod curl-helper -n llm-d-lab --ignore-not-found --force --grace-period=0 2>/dev/null || true
oc delete pod helper -n llm-d-lab --ignore-not-found --force --grace-period=0 2>/dev/null || true

echo "Restoring RHOAI EPP image..."
RHOAI_EPP_IMAGE=$(oc get configmap kserve-parameters \
  -n redhat-ods-applications \
  -o jsonpath="{.data.kserve-llm-d-inference-scheduler}" 2>/dev/null || echo "")

if [[ -n "$RHOAI_EPP_IMAGE" ]]; then
  oc set image deployment/llm-d-sim-epp -n llm-d-lab \
    "epp=${RHOAI_EPP_IMAGE}" 2>/dev/null || true
  echo "  Restored EPP image from kserve-parameters"
else
  echo "  WARNING: Could not discover RHOAI EPP image from kserve-parameters ConfigMap"
  echo "  EPP container image was not restored — verify manually with:"
  echo "    oc get configmap kserve-parameters -n redhat-ods-applications -o yaml"
fi

oc patch deployment llm-d-sim-epp -n llm-d-lab --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/args",
   "value":[
     "--pool-name=llm-d-sim-pool",
     "--pool-namespace=llm-d-lab",
     "--pool-group=inference.networking.k8s.io",
     "--config-file=/config/default-plugins.yaml",
     "--zap-encoder=json",
     "--secure-serving=false",
     "--metrics-endpoint-auth=false",
     "--tracing=false"
   ]}
]' 2>/dev/null || true

echo "Restoring simulator baseline args (removes kvcache if enabled)..."
oc patch deployment llm-d-sim -n llm-d-lab --type=json -p='[
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

echo "Restoring original EPP config..."
oc apply -n llm-d-lab -f - <<'EOF'
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
EOF

echo "Restarting EPP..."
oc delete pod -n llm-d-lab -l app=llm-d-sim-epp

echo "Scaling up uniform simulator..."
oc scale deployment -n llm-d-lab llm-d-sim --replicas=3

echo "Waiting for pods..."
oc wait -n llm-d-lab deployment/llm-d-sim --for=condition=Available --timeout=600s
oc wait -n llm-d-lab deployment/llm-d-sim-epp --for=condition=Available --timeout=180s

echo ""
echo "=== Verifying cluster state ==="

echo ""
echo "Pods:"
oc get pods -n llm-d-lab

echo ""
echo "Deployments:"
oc get deployments -n llm-d-lab

echo ""
echo "=== cleanup complete ==="

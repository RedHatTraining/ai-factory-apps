#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in to OpenShift."; exit 1; }

echo "[INFO] Enabling User Workload Monitoring..."
oc apply -f "$SCRIPT_DIR/1-cluster-monitoring-config.yaml"

echo "[INFO] Configuring UWM Prometheus instance..."
oc apply -f "$SCRIPT_DIR/2-user-workload-monitoring-config.yaml"

echo "[INFO] Waiting for UWM Prometheus pods to be created..."
retries=0
until oc get pod -l app.kubernetes.io/name=prometheus \
  -n openshift-user-workload-monitoring -o name 2>/dev/null | grep -q .; do
  retries=$((retries + 1))
  if [ "$retries" -ge 30 ]; then
    echo "[FAIL] UWM Prometheus pods not created after 60 seconds."
    exit 1
  fi
  sleep 2
done
echo "[INFO] Pods found. Waiting for Ready state..."
oc wait pod -l app.kubernetes.io/name=prometheus \
  -n openshift-user-workload-monitoring \
  --for=condition=Ready --timeout=180s

echo "[INFO] Creating monitoring-metrics project..."
oc new-project monitoring-metrics > /dev/null || oc project monitoring-metrics
oc label namespace monitoring-metrics \
  opendatahub.io/dashboard=true \
  modelmesh-enabled=false \
  --overwrite

echo "[INFO] Deploying vLLM ServingRuntime..."
oc apply -f "$SCRIPT_DIR/3-serving-runtime.yaml"

echo "[INFO] Deploying granite-monitor InferenceService..."
oc apply -f "$SCRIPT_DIR/4-inferenceservice.yaml"

echo "[INFO] Waiting for InferenceService to be Ready (up to 20 minutes)..."
oc wait --for=condition=Ready \
  inferenceservice/granite-monitor -n monitoring-metrics \
  --timeout=1200s

echo "[INFO] Sending inference requests to seed vLLM metrics..."
POD=$(oc get pod -n monitoring-metrics \
  -l serving.kserve.io/inferenceservice=granite-monitor \
  -o jsonpath='{.items[0].metadata.name}')
QUESTIONS=(
  "What is Kubernetes?"
  "What is a container runtime?"
  "What is Prometheus?"
  "What is GPU memory utilization?"
  "What is a service mesh?"
  "What is model inference?"
  "What is a KV cache?"
  "What is time to first token?"
  "What is a vector database?"
  "What is retrieval augmented generation?"
)
for i in "${!QUESTIONS[@]}"; do
  Q="${QUESTIONS[$i]}"
  oc exec -n monitoring-metrics "$POD" -c kserve-container -- \
    curl -s http://localhost:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"granite-monitor\",\"messages\":[{\"role\":\"user\",\"content\":\"${Q} Answer in one sentence.\"}],\"max_tokens\":30}" \
    > /dev/null
  echo "[INFO] Request $((i+1))/10 complete."
done

echo "[OK] Setup complete."

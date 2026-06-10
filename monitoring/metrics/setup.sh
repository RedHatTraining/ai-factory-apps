#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in to OpenShift."; exit 1; }

echo "[INFO] Step 1: Enabling User Workload Monitoring..."
oc apply -f "$SCRIPT_DIR/1-cluster-monitoring-config.yaml"

echo "[INFO] Step 2: Configuring UWM Prometheus instance..."
oc apply -f "$SCRIPT_DIR/2-user-workload-monitoring-config.yaml"

echo "[INFO] Step 3: Waiting for UWM Prometheus pods to be running..."
oc wait pod -l app.kubernetes.io/name=prometheus \
  -n openshift-user-workload-monitoring \
  --for=condition=Ready --timeout=180s

echo "[INFO] Step 4: Creating monitoring-metrics project..."
oc new-project monitoring-metrics 2>/dev/null || oc project monitoring-metrics

echo "[INFO] Step 5: Deploying granite-monitor InferenceService..."
oc apply -f "$SCRIPT_DIR/3-inferenceservice.yaml"

echo "[INFO] Step 6: Waiting for InferenceService to be Ready (up to 10 minutes)..."
oc wait --for=condition=Ready \
  inferenceservice/granite-monitor -n monitoring-metrics \
  --timeout=600s

echo "[INFO] Step 7: Sending inference request to seed vLLM metrics..."
ENDPOINT=$(oc get inferenceservice granite-monitor \
  -n monitoring-metrics -o jsonpath='{.status.url}')
curl -sk "${ENDPOINT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
  "model": "granite-monitor",
  "messages": [{"role": "user", "content": "What is OpenShift AI?"}],
  "max_tokens": 50
}' > /dev/null

echo "[OK] Setup complete."

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_PROJECT="monitoring-alerts"
ISVC_NAME="granite-monitor"

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in. Run: oc login -u admin -p PASSWORD https://API_URL"; exit 1; }

# ── 1. Enable User Workload Monitoring ────────────────────────────────────────

echo "[INFO] Enabling User Workload Monitoring..."
oc apply -f "$SCRIPT_DIR/1-uwm-config.yaml"

echo "[INFO] Waiting for user workload monitoring pods..."
oc wait pod -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus \
  --for=condition=Ready --timeout=180s 2>/dev/null || \
  echo "[INFO] UWM pods starting up, continuing..."

# ── 2. Create lab project ─────────────────────────────────────────────────────

if ! oc get project "$LAB_PROJECT" &>/dev/null; then
  echo "[INFO] Creating project $LAB_PROJECT..."
  oc new-project "$LAB_PROJECT"
else
  echo "[INFO] Project $LAB_PROJECT already exists, skipping."
  oc project "$LAB_PROJECT"
fi

# ── 3. Create vLLM ServingRuntime ─────────────────────────────────────────────

if ! oc get servingruntime vllm-cuda-runtime -n "$LAB_PROJECT" &>/dev/null; then
  echo "[INFO] Creating vLLM CUDA ServingRuntime..."
  oc process vllm-cuda-runtime-template -n redhat-ods-applications | \
    oc apply -n "$LAB_PROJECT" -f -
else
  echo "[INFO] ServingRuntime vllm-cuda-runtime already exists, skipping."
fi

# ── 4. Deploy InferenceService with vLLM ──────────────────────────────────────

echo "[INFO] Deploying InferenceService $ISVC_NAME..."
oc apply -f "$SCRIPT_DIR/2-inferenceservice.yaml"

echo "[INFO] Waiting for InferenceService to become ready (this may take several minutes)..."
oc wait inferenceservice "$ISVC_NAME" -n "$LAB_PROJECT" \
  --for=condition=Ready --timeout=900s

# ── 5. Create ServiceMonitor for vLLM metrics ────────────────────────────────

echo "[INFO] Creating ServiceMonitor for vLLM metrics..."
oc apply -f "$SCRIPT_DIR/3-servicemonitor.yaml"

# ── 6. Expose model endpoint via route ───────────────────────────────────────

if ! oc get route "$ISVC_NAME" -n "$LAB_PROJECT" &>/dev/null; then
  echo "[INFO] Creating route for model endpoint..."
  oc expose svc "${ISVC_NAME}-metrics" -n "$LAB_PROJECT" --name="$ISVC_NAME"
else
  echo "[INFO] Route $ISVC_NAME already exists, skipping."
fi

# ── 7. Seed vLLM metrics with an initial request ─────────────────────────────

echo "[INFO] Sending initial inference request to seed metrics..."

ISVC_URL="http://$(oc get route "$ISVC_NAME" -n "$LAB_PROJECT" \
  -o jsonpath='{.spec.host}')"
TOKEN=$(oc whoami -t)

curl -s "${ISVC_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{
    "model": "granite-monitor",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 10
  }' > /dev/null 2>&1 || echo "[WARN] Initial request may have timed out, metrics might need a moment to appear."

echo "[OK] Setup complete."

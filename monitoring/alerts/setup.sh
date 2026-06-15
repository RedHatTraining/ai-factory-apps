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

# ── 3. Deploy InferenceService with vLLM ──────────────────────────────────────

echo "[INFO] Deploying InferenceService $ISVC_NAME..."
oc apply -f "$SCRIPT_DIR/2-inferenceservice.yaml"

echo "[INFO] Waiting for InferenceService to become ready (this may take several minutes)..."
oc wait inferenceservice "$ISVC_NAME" -n "$LAB_PROJECT" \
  --for=condition=Ready --timeout=600s

# ── 4. Create ServiceMonitor for vLLM metrics ────────────────────────────────

echo "[INFO] Creating ServiceMonitor for vLLM metrics..."
oc apply -f "$SCRIPT_DIR/3-servicemonitor.yaml"

# ── 5. Seed vLLM metrics with an initial request ─────────────────────────────

echo "[INFO] Sending initial inference request to seed metrics..."

ISVC_URL=$(oc get inferenceservice "$ISVC_NAME" -n "$LAB_PROJECT" \
  -o jsonpath='{.status.url}')
TOKEN=$(oc whoami -t)

curl -sk "${ISVC_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{
    "model": "granite-3.1-2b-instruct",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 10
  }' > /dev/null 2>&1 || echo "[WARN] Initial request may have timed out, metrics might need a moment to appear."

echo "[OK] Setup complete."

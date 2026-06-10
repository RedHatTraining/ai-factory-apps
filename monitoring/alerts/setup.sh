#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_PROJECT="monitoring-alerts"
ISVC_NAME="granite-3-2b"

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in. Run: oc login -u admin -p PASSWORD https://API_URL"; exit 1; }

# ── 1. Enable User Workload Monitoring ────────────────────────────────────────

echo "[INFO] Enabling User Workload Monitoring..."

oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF

oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
data:
  config.yaml: ""
EOF

echo "[INFO] Waiting for user workload monitoring pods..."
oc wait pod -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus \
  --for=condition=Ready --timeout=180s 2>/dev/null || true

# ── 2. Create lab project ─────────────────────────────────────────────────────

if ! oc get project "$LAB_PROJECT" &>/dev/null; then
  echo "[INFO] Creating project $LAB_PROJECT..."
  oc new-project "$LAB_PROJECT"
else
  echo "[INFO] Project $LAB_PROJECT already exists, skipping."
  oc project "$LAB_PROJECT"
fi

# ── 3. Deploy InferenceService ────────────────────────────────────────────────

echo "[INFO] Deploying InferenceService $ISVC_NAME..."
oc apply -f "$SCRIPT_DIR/1-isvc.yaml"

echo "[INFO] Waiting for InferenceService to become ready (this may take several minutes)..."
oc wait inferenceservice "$ISVC_NAME" -n "$LAB_PROJECT" \
  --for=condition=Ready --timeout=600s

# ── 4. Seed vLLM metrics ─────────────────────────────────────────────────────

echo "[INFO] Sending initial inference request to seed vLLM metrics..."

oc port-forward -n "$LAB_PROJECT" "svc/${ISVC_NAME}-predictor" 8080:8080 &
PF_PID=$!
sleep 5

curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite-3.2-2b-instruct",
    "messages": [{"role": "user", "content": "Say hello."}],
    "max_tokens": 10
  }' > /dev/null 2>&1 || true

kill $PF_PID 2>/dev/null || true
wait $PF_PID 2>/dev/null || true

echo "[OK] Setup complete."

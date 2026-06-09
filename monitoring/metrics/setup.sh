#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_PROJECT="monitoring-metrics"

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in. Run: oc login -u admin -p PASSWORD https://API_URL"; exit 1; }

# ── 1. Ensure UWM is disabled ────────────────────────────────────────────────

echo "[INFO] Ensuring User Workload Monitoring is disabled..."
oc delete configmap cluster-monitoring-config \
  -n openshift-monitoring --ignore-not-found
oc delete configmap user-workload-monitoring-config \
  -n openshift-user-workload-monitoring --ignore-not-found

# ── 2. Create project ────────────────────────────────────────────────────────

if ! oc get project "$LAB_PROJECT" &>/dev/null; then
  echo "[INFO] Creating project $LAB_PROJECT..."
  oc new-project "$LAB_PROJECT"
else
  echo "[INFO] Project $LAB_PROJECT already exists, skipping."
fi

# ── 3. Deploy InferenceService ────────────────────────────────────────────────

echo "[INFO] Deploying InferenceService llm-model..."
oc apply -f "$SCRIPT_DIR/1-inferenceservice.yaml"

echo "[INFO] Waiting for InferenceService to be ready (this may take several minutes)..."
oc wait inferenceservice/llm-model \
  -n "$LAB_PROJECT" \
  --for=condition=Ready \
  --timeout=600s

echo "[OK] Setup complete."

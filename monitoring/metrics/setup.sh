#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_PROJECT="monitoring-metrics"
LABS_DIR="${HOME}/AI0033L/labs/${LAB_PROJECT}"

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in. Run: oc login -u admin -p PASSWORD https://API_URL"; exit 1; }

# ── 1. Create project ────────────────────────────────────────────────────────

if ! oc project $LAB_PROJECT &>/dev/null; then
  echo "[INFO] Creating project ${LAB_PROJECT}..."
  oc new-project $LAB_PROJECT
else
  echo "[INFO] Project ${LAB_PROJECT} already exists, skipping."
fi

# ── 2. Instantiate vLLM CUDA ServingRuntime from template ────────────────────
if ! oc get servingruntime vllm-cuda-runtime -n $LAB_PROJECT &>/dev/null; then
  echo "[INFO] Creating vLLM CUDA ServingRuntime from template..."
  oc process vllm-cuda-runtime-template -n redhat-ods-applications \
    | oc apply -n $LAB_PROJECT -f -
else
  echo "[INFO] ServingRuntime vllm-cuda-runtime already exists, skipping."
fi

# ── 3. Create labs directory and copy InferenceService manifest ───────────────

echo "[INFO] Creating labs directory at ${LABS_DIR}..."
mkdir -p "$LABS_DIR"
cp "$SCRIPT_DIR/inference-service.yaml" "$LABS_DIR/inference-service.yaml"

echo "[OK] Setup complete."

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_PROJECT="monitoring-metrics"

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in. Run: oc login -u admin -p PASSWORD https://API_URL"; exit 1; }

# ── 1. Create lab project ────────────────────────────────────────────────────

if ! oc project "$LAB_PROJECT" &>/dev/null; then
  echo "[INFO] Creating project $LAB_PROJECT..."
  oc new-project "$LAB_PROJECT"
else
  echo "[INFO] Project $LAB_PROJECT already exists, skipping."
fi

# ── 2. Deploy vLLM InferenceService ──────────────────────────────────────────

echo "[INFO] Deploying vllm-model InferenceService..."
oc apply -f "$SCRIPT_DIR/1-inferenceservice.yaml"

echo "[INFO] Waiting for InferenceService to become ready (this may take several minutes)..."
oc wait --for=condition=Ready inferenceservice/vllm-model \
  -n "$LAB_PROJECT" --timeout=600s

echo "[OK] Setup complete."

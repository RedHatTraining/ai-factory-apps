#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_PROJECT="serving-genai"

command -v oc &>/dev/null  || { echo "[FAIL] oc is not installed."; exit 1; }
command -v uv &>/dev/null  || { echo "[FAIL] uv is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in. Run: oc login -u admin -p PASSWORD https://API_URL"; exit 1; }

# ── 1. MySQL + ModelRegistry ──────────────────────────────────────────────────

echo "[INFO] Deploying MySQL and model registry..."
oc apply -f "$SCRIPT_DIR/1-mysql.yaml"
oc rollout status deployment/mysql -n rhoai-model-registries --timeout=120s
oc apply -f "$SCRIPT_DIR/2-model-registry.yaml"

echo "[INFO] Waiting for model registry pod..."
oc wait pod -n rhoai-model-registries -l app=serving-genai-registry \
  --for=condition=Ready --timeout=180s

# ── 2. Register model ─────────────────────────────────────────────────────────

echo "[INFO] Registering model..."
uv run "$SCRIPT_DIR/register_model.py"

# ── 3. GPU hardware profile ───────────────────────────────────────────────────
# This GE uses the gpu-profile already included in RHDP env.
echo "[INFO] Applying GPU hardware profile..."
oc apply -f "$SCRIPT_DIR/3-gpu-profile.yaml"

echo "[OK] Setup complete."

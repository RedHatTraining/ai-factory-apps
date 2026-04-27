#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_PROJECT="serving-deploy-lab"

oc whoami &>/dev/null || { echo "[FAIL] Not logged in. Run: oc login -u admin -p PASSWORD https://API_URL"; exit 1; }

echo "[INFO] Deleting DS project..."
oc delete project $LAB_PROJECT --ignore-not-found

echo "[INFO] Deleting GPU hardware profile..."
oc delete -f "$SCRIPT_DIR/3-gpu-profile.yaml" --ignore-not-found

echo "[INFO] Deleting model registry..."
oc delete -f "$SCRIPT_DIR/2-model-registry.yaml" --ignore-not-found

echo "[INFO] Deleting MySQL..."
oc delete -f "$SCRIPT_DIR/1-mysql.yaml" --ignore-not-found

echo "[OK] Teardown complete."

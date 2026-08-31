#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_PROJECT="serving-versions"
REGISTRY_DIR="$SCRIPT_DIR/../registry"

command -v oc &>/dev/null  || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in. Run: oc login -u admin -p PASSWORD https://API_URL"; exit 1; }

echo "[INFO] Deleting exercise project..."
oc delete project $LAB_PROJECT --ignore-not-found

echo "[INFO] Deleting model registry..."
oc delete -f "$REGISTRY_DIR/2-model-registry.yaml" --ignore-not-found

echo "[INFO] Deleting MySQL..."
oc delete -f "$REGISTRY_DIR/1-deploy-mysqldb.yaml" --ignore-not-found

echo "[OK] Teardown complete."

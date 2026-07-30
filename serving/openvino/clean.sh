#!/usr/bin/env bash
set -euo pipefail

LAB_PROJECT="serving-openvino"

command -v oc &>/dev/null  || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in. Run: oc login -u admin -p PASSWORD https://API_URL"; exit 1; }

echo "[INFO] Deleting project $LAB_PROJECT..."
oc delete project $LAB_PROJECT --ignore-not-found

echo "[OK] Teardown complete."

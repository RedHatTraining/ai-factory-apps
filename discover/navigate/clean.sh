#!/usr/bin/env bash
set -euo pipefail

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in to OpenShift."; exit 1; }

echo "[INFO] Deleting lab project navigate-lab..."
oc delete project navigate-lab --ignore-not-found

echo "[INFO] Cleanup complete."

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in to OpenShift."; exit 1; }

echo "[INFO] Creating lab project..."
oc new-project navigate-lab --skip-config-write 2>/dev/null \
  || oc project navigate-lab
oc label namespace navigate-lab "opendatahub.io/dashboard=true" --overwrite

echo "[INFO] Creating data connection..."
oc apply -f "$SCRIPT_DIR/1-data-connection.yaml"

echo "[INFO] Setup complete."

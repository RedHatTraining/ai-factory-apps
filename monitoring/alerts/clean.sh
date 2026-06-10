#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_PROJECT="monitoring-alerts"

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in. Run: oc login -u admin -p PASSWORD https://API_URL"; exit 1; }

echo "[INFO] Deleting GPU health alerts..."
oc delete -f "$SCRIPT_DIR/gpu-alerts.yaml" --ignore-not-found

echo "[INFO] Deleting inference SLO alerts..."
oc delete -f "$SCRIPT_DIR/vllm-alerts.yaml" --ignore-not-found

echo "[INFO] Deleting model deployment..."
oc delete -f "$SCRIPT_DIR/1-isvc.yaml" --ignore-not-found

echo "[INFO] Deleting project..."
oc delete project "$LAB_PROJECT" --ignore-not-found

echo "[INFO] Removing User Workload Monitoring configuration..."
oc delete configmap cluster-monitoring-config -n openshift-monitoring --ignore-not-found
oc delete configmap user-workload-monitoring-config -n openshift-user-workload-monitoring --ignore-not-found

echo "[OK] Teardown complete."

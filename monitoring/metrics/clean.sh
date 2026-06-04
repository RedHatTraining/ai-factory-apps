#!/usr/bin/env bash
set -euo pipefail

LAB_PROJECT="monitoring-metrics"
LABS_DIR="${HOME}/AI0033L/labs/${LAB_PROJECT}"

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in. Run: oc login -u admin -p PASSWORD https://API_URL"; exit 1; }

echo "[1/5] Deleting InferenceService..."
oc delete inferenceservice $LAB_PROJECT -n $LAB_PROJECT --ignore-not-found

echo "[2/5] Deleting lab project..."
oc delete project $LAB_PROJECT --ignore-not-found

echo "[3/5] Removing cluster-monitoring-config ConfigMap..."
oc delete configmap cluster-monitoring-config -n openshift-monitoring --ignore-not-found

echo "[4/5] Removing user-workload-monitoring-config ConfigMap..."
oc delete configmap user-workload-monitoring-config -n openshift-user-workload-monitoring --ignore-not-found

echo "[5/5] Removing labs directory..."
rm -rf "$LABS_DIR"

echo "[OK] Teardown complete."

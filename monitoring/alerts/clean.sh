#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_PROJECT="monitoring-alerts"

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in. Run: oc login -u admin -p PASSWORD https://API_URL"; exit 1; }

echo "[INFO] Deleting GPU alert rules..."
oc delete prometheusrule gpu-health-alerts -n nvidia-gpu-operator --ignore-not-found

echo "[INFO] Deleting inference alert rules..."
oc delete prometheusrule vllm-inference-alerts -n "$LAB_PROJECT" --ignore-not-found

echo "[INFO] Deleting lab project..."
oc delete project "$LAB_PROJECT" --ignore-not-found

echo "[INFO] Removing monitoring ConfigMaps..."
oc delete configmap cluster-monitoring-config -n openshift-monitoring --ignore-not-found
oc delete configmap user-workload-monitoring-config -n openshift-user-workload-monitoring --ignore-not-found

echo "[OK] Cleanup complete."

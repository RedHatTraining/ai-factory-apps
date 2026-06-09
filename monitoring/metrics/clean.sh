#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_PROJECT="monitoring-metrics"

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in. Run: oc login -u admin -p PASSWORD https://API_URL"; exit 1; }

echo "[1/4] Removing vllm-model InferenceService..."
oc delete -f "$SCRIPT_DIR/1-inferenceservice.yaml" --ignore-not-found

echo "[2/4] Removing cluster-monitoring-config ConfigMap..."
oc delete configmap cluster-monitoring-config \
  -n openshift-monitoring --ignore-not-found

echo "[3/4] Removing user-workload-monitoring-config ConfigMap..."
oc delete configmap user-workload-monitoring-config \
  -n openshift-user-workload-monitoring --ignore-not-found

echo "[4/4] Removing lab project..."
oc delete project "$LAB_PROJECT" --ignore-not-found

echo "[OK] Teardown complete."

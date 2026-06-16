#!/usr/bin/env bash
set -euo pipefail

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in to OpenShift."; exit 1; }

echo "[1/3] Removing monitoring-metrics project..."
oc delete project monitoring-metrics --ignore-not-found

echo "[2/3] Removing cluster-monitoring-config ConfigMap..."
oc delete configmap cluster-monitoring-config \
  -n openshift-monitoring --ignore-not-found

echo "[3/3] Removing user-workload-monitoring-config ConfigMap..."
oc delete configmap user-workload-monitoring-config \
  -n openshift-user-workload-monitoring --ignore-not-found

echo "[OK] Teardown complete."

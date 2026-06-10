#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_NS="monitoring-dashboards"
GRAFANA_NS="grafana-monitoring"
ISVC_NAME="granite-3-2b"

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in. Run: oc login -u admin -p PASSWORD https://API_URL"; exit 1; }

echo "[1/9] Deleting Grafana dashboards..."
oc delete grafanadashboards --all -n "$GRAFANA_NS" --ignore-not-found

echo "[2/9] Deleting Grafana datasource..."
oc delete grafanadatasource prometheus-grafanadatasource -n "$GRAFANA_NS" --ignore-not-found

echo "[3/9] Deleting Grafana instance..."
oc delete grafana grafana -n "$GRAFANA_NS" --ignore-not-found

echo "[4/9] Deleting RBAC resources..."
oc delete clusterrolebinding grafana-cluster-monitoring-view --ignore-not-found
oc delete secret grafana-sa-token -n "$GRAFANA_NS" --ignore-not-found
oc delete serviceaccount grafana-sa -n "$GRAFANA_NS" --ignore-not-found

echo "[5/9] Deleting Grafana Operator..."
CSV=$(oc get csv -n "$GRAFANA_NS" -l operators.coreos.com/grafana-operator.${GRAFANA_NS}="" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
oc delete subscription grafana-operator -n "$GRAFANA_NS" --ignore-not-found
if [ -n "$CSV" ]; then
  oc delete csv "$CSV" -n "$GRAFANA_NS" --ignore-not-found
fi

echo "[6/9] Deleting Grafana namespace..."
oc delete project "$GRAFANA_NS" --ignore-not-found

echo "[7/10] Deleting InferenceService..."
oc delete inferenceservice "$ISVC_NAME" -n "$MODEL_NS" --ignore-not-found

echo "[8/10] Deleting ServingRuntime..."
oc delete servingruntime vllm-runtime -n "$MODEL_NS" --ignore-not-found

echo "[9/10] Deleting ServiceMonitor..."
oc delete servicemonitor vllm-metrics -n "$MODEL_NS" --ignore-not-found
oc delete project "$MODEL_NS" --ignore-not-found

echo "[10/10] Restoring cluster monitoring configuration..."
oc delete configmap cluster-monitoring-config -n openshift-monitoring --ignore-not-found
oc delete configmap user-workload-monitoring-config -n openshift-user-workload-monitoring --ignore-not-found

echo "[OK] Teardown complete."

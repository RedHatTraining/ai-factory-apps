#!/usr/bin/env bash
set -euo pipefail

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in to OpenShift."; exit 1; }

# --------------------------------------------------------------------------
# This script removes only resources that our setup.sh and 5-deploy-grafana.sh
# created. It does NOT force-delete operator-managed resources (CSVs, CRDs,
# InstallPlans) — OLM reconciles those automatically when the Subscription
# is removed.
#
# IMPORTANT: Grafana CRs (dashboards, datasources, folders) have finalizers
# managed by the Grafana Operator. We must delete these CRs BEFORE removing
# the operator (via namespace deletion), so the operator can process the
# finalizers. Otherwise the namespace gets stuck in Terminating state.
# --------------------------------------------------------------------------

echo "[1/7] Removing Prometheus alert rules..."
oc delete prometheusrule inference-slo-alerts \
  -n monitoring-metrics --ignore-not-found
oc delete prometheusrule gpu-health-alerts \
  -n nvidia-gpu-operator --ignore-not-found

echo "[2/7] Removing Grafana custom resources (before operator removal)..."
if oc get ns user-grafana &>/dev/null; then
  oc delete grafanadashboard --all -n user-grafana --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete grafanadatasource --all -n user-grafana --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete grafanafolder --all -n user-grafana --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete grafana --all -n user-grafana --ignore-not-found --timeout=30s 2>/dev/null || true
  echo "[INFO] Waiting for operator to process finalizers..."
  sleep 5
fi

echo "[3/7] Removing user-grafana namespace..."
oc delete namespace user-grafana --ignore-not-found --timeout=60s 2>/dev/null || true

echo "[4/7] Removing cluster-scoped RBAC..."
oc delete clusterrolebinding cluster-monitoring-view-user-grafana --ignore-not-found
oc delete clusterrolebinding grafana-proxy-cluster --ignore-not-found
oc delete clusterrolebinding grafana-alertmanager-view --ignore-not-found
oc delete clusterrole grafana-proxy --ignore-not-found
oc delete clusterrole alertmanager-api-view --ignore-not-found

echo "[5/7] Removing monitoring-metrics project..."
oc delete project monitoring-metrics --ignore-not-found --timeout=60s 2>/dev/null || true

echo "[6/7] Removing UWM configuration..."
oc delete configmap cluster-monitoring-config \
  -n openshift-monitoring --ignore-not-found
oc delete configmap user-workload-monitoring-config \
  -n openshift-user-workload-monitoring --ignore-not-found

echo "[7/7] Verifying cleanup..."
echo "  PrometheusRules remaining:"
oc get prometheusrule -n monitoring-metrics --no-headers 2>/dev/null || echo "    (none)"
oc get prometheusrule gpu-health-alerts -n nvidia-gpu-operator --no-headers 2>/dev/null || echo "    (none in nvidia-gpu-operator)"

echo "[OK] Teardown complete."

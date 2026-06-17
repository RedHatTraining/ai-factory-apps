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

echo "[1/5] Removing Grafana custom resources (before operator removal)..."
if oc get ns user-grafana &>/dev/null; then
  oc delete grafanadashboard --all -n user-grafana --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete grafanadatasource --all -n user-grafana --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete grafanafolder --all -n user-grafana --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete grafana --all -n user-grafana --ignore-not-found --timeout=30s 2>/dev/null || true
  echo "[INFO] Waiting for operator to process finalizers..."
  sleep 5
fi

echo "[2/5] Removing user-grafana namespace..."
oc delete namespace user-grafana --ignore-not-found --timeout=60s 2>/dev/null || true

echo "[3/5] Removing cluster-scoped RBAC..."
oc delete clusterrolebinding cluster-monitoring-view-user-grafana --ignore-not-found
oc delete clusterrolebinding grafana-proxy-cluster --ignore-not-found
oc delete clusterrole grafana-proxy --ignore-not-found

echo "[4/5] Removing monitoring-metrics project..."
oc delete project monitoring-metrics --ignore-not-found --timeout=60s 2>/dev/null || true

echo "[5/5] Removing UWM configuration..."
oc delete configmap cluster-monitoring-config \
  -n openshift-monitoring --ignore-not-found
oc delete configmap user-workload-monitoring-config \
  -n openshift-user-workload-monitoring --ignore-not-found

echo "[OK] Teardown complete."

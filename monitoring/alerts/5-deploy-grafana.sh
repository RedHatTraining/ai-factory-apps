#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_DIR="$SCRIPT_DIR/rhoai-uwm/rhoai-uwm-grafana/overlays/rhoai-uwm-user-grafana-app"

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in to OpenShift."; exit 1; }

# Returns 0 when a datasource or dashboard CR has been synced to the Grafana
# instance. The operator sets "None of the available Grafana instances matched
# the selector" while the Grafana CR is still reconciling. oc wait can't
# distinguish this from real success because both set status=True, so we
# check the message text instead.
cr_synced() {
  local kind="$1" name="$2"
  local msg
  msg=$(oc get "$kind" "$name" -n user-grafana \
    -o jsonpath='{.status.conditions[0].message}' 2>/dev/null)
  [ -n "$msg" ] && ! echo "$msg" | grep -q "None of the available"
}

wait_for_cr_sync() {
  local kind="$1" name="$2" timeout="$3"
  local elapsed=0
  while ! cr_synced "$kind" "$name"; do
    elapsed=$((elapsed + 3))
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "[FAIL] $name not synced after ${timeout}s. Check:"
      echo "       oc get $kind $name -n user-grafana -o yaml"
      exit 1
    fi
    sleep 3
  done
}

echo "[1/8] Applying namespace, operator group, and Grafana Operator subscription..."
oc apply -f "$OVERLAY_DIR/namespace.yaml"
oc apply -f "$OVERLAY_DIR/operator-group.yaml"
oc apply -k "$SCRIPT_DIR/rhoai-uwm/rhoai-uwm-grafana/base/operator" \
  -n user-grafana

echo "[2/8] Waiting for Grafana CRDs to be established..."
oc wait crd grafanas.grafana.integreatly.org \
  --for=create --timeout=300s
oc wait crd grafanas.grafana.integreatly.org \
  --for=condition=Established --timeout=60s
echo "[OK] Grafana CRDs are established."

echo "[3/8] Applying full kustomize overlay (instance + dashboards)..."
oc apply -k "$OVERLAY_DIR"

echo "[4/8] Waiting for Grafana pods to be Ready..."
oc wait pod -l app=grafana -n user-grafana \
  --for=create --timeout=120s
oc wait pod -l app=grafana -n user-grafana \
  --for=condition=Ready --timeout=300s
echo "[OK] Grafana pods are ready."

echo "[5/8] Waiting for Grafana instance to finish reconciling..."
oc wait grafana/grafana -n user-grafana \
  --for=jsonpath='{.status.stageStatus}'=success --timeout=180s
echo "[OK] Grafana instance is fully reconciled."

echo "[6/8] Re-applying grafana-auth-secret (SA token for Thanos access)..."
oc apply -f "$SCRIPT_DIR/5-grafana-auth-secret.yaml"

echo "[7/8] Triggering datasource and dashboard re-sync..."
oc annotate grafanadatasource prometheus-grafanadatasource \
  -n user-grafana resync="$(date +%s)" --overwrite
oc annotate grafanadashboard nvidia-gpu-vllm-metrics-dashboard \
  -n user-grafana resync="$(date +%s)" --overwrite

echo "[8/8] Waiting for datasource and dashboards to sync..."
wait_for_cr_sync grafanadatasource prometheus-grafanadatasource 120
echo "[OK] Datasource synced."
wait_for_cr_sync grafanadashboard nvidia-gpu-vllm-metrics-dashboard 120
echo "[OK] nvidia-gpu-vllm-metrics-dashboard synced."

GRAFANA_URL="https://$(oc get route grafana-route -n user-grafana -o jsonpath='{.spec.host}')"
echo ""
echo "Grafana deployment complete."
echo "  Route: $GRAFANA_URL"
echo "  Log in with your OpenShift credentials."

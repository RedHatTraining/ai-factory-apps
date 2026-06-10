#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_NS="monitoring-dashboards"
GRAFANA_NS="grafana-monitoring"
ISVC_NAME="granite-3-2b"

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in. Run: oc login -u admin -p PASSWORD https://API_URL"; exit 1; }

# ── 1. Enable User Workload Monitoring ────────────────────────────────────────

echo "[INFO] Enabling User Workload Monitoring..."

oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF

oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
data:
  config.yaml: ""
EOF

echo "[INFO] Waiting for user workload monitoring pods..."
sleep 10
oc wait pod -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus \
  --for=condition=Ready --timeout=180s 2>/dev/null || true

# ── 2. Create model project and deploy InferenceService ───────────────────────

if ! oc get project "$MODEL_NS" &>/dev/null; then
  echo "[INFO] Creating project $MODEL_NS..."
  oc new-project "$MODEL_NS"
else
  echo "[INFO] Project $MODEL_NS already exists, skipping."
fi

echo "[INFO] Deploying InferenceService $ISVC_NAME..."
oc apply -f - <<EOF
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: ${ISVC_NAME}
  namespace: ${MODEL_NS}
  annotations:
    serving.kserve.io/deploymentMode: RawDeployment
    serving.knative.dev/targetBurstCapacity: "0"
  labels:
    opendatahub.io/dashboard: "true"
spec:
  predictor:
    model:
      modelFormat:
        name: vLLM
      runtime: vllm-runtime
      storageUri: oci://registry.redhat.io/rhelai1/granite-3-2b-instruct:latest
      resources:
        limits:
          nvidia.com/gpu: "1"
        requests:
          nvidia.com/gpu: "1"
EOF

echo "[INFO] Waiting for InferenceService to become ready (this may take several minutes)..."
oc wait inferenceservice "$ISVC_NAME" -n "$MODEL_NS" \
  --for=condition=Ready --timeout=600s

# ── 3. Create ServiceMonitor ─────────────────────────────────────────────────

echo "[INFO] Creating ServiceMonitor for vLLM metrics..."
oc apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: vllm-metrics
  namespace: ${MODEL_NS}
spec:
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
  namespaceSelector:
    matchNames:
      - ${MODEL_NS}
  selector:
    matchLabels:
      serving.kserve.io/inferenceservice: ${ISVC_NAME}
EOF

# ── 4. Create Grafana namespace and install operator ──────────────────────────

if ! oc get project "$GRAFANA_NS" &>/dev/null; then
  echo "[INFO] Creating namespace $GRAFANA_NS..."
  oc new-project "$GRAFANA_NS"
else
  echo "[INFO] Namespace $GRAFANA_NS already exists, skipping."
fi

echo "[INFO] Installing Grafana Operator..."
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: grafana-operator-group
  namespace: ${GRAFANA_NS}
spec:
  targetNamespaces:
    - ${GRAFANA_NS}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: grafana-operator
  namespace: ${GRAFANA_NS}
spec:
  channel: v5
  name: grafana-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

echo "[INFO] Waiting for Grafana Operator CSV to succeed..."
for i in $(seq 1 60); do
  CSV=$(oc get csv -n "$GRAFANA_NS" -l operators.coreos.com/grafana-operator.${GRAFANA_NS}="" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$CSV" ]; then
    PHASE=$(oc get csv "$CSV" -n "$GRAFANA_NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ "$PHASE" = "Succeeded" ]; then
      echo "[INFO] Grafana Operator CSV $CSV is ready."
      break
    fi
  fi
  if [ "$i" -eq 60 ]; then
    echo "[FAIL] Timed out waiting for Grafana Operator CSV."
    exit 1
  fi
  sleep 10
done

echo "[OK] Setup complete."

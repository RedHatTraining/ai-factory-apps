#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_PROJECT="serving-predictive"
WORKBENCH_NAME="serving-predictive-wb"

command -v oc &>/dev/null  || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in. Run: oc login -u admin -p PASSWORD https://API_URL"; exit 1; }

# ── 1. Create project ────────────────────────────────────────────────────────

if ! oc project $LAB_PROJECT &>/dev/null; then
  echo "[INFO] Creating project $LAB_PROJECT..."
  oc new-project $LAB_PROJECT
  oc label namespace $LAB_PROJECT opendatahub.io/dashboard=true
  echo "[INFO] Waiting for project to be ready..."
  sleep 5
else
  echo "[INFO] Project $LAB_PROJECT already exists, skipping."
fi

# ── 1b. Free cluster capacity ───────────────────────────────────────────────

echo "[INFO] Scaling RHOAI dashboard to 1 replica to free cluster resources..."
oc scale deployment rhods-dashboard -n redhat-ods-applications --replicas=1

# ── 2. Deploy MinIO ──────────────────────────────────────────────────────────

echo "[INFO] Deploying MinIO..."
oc apply -f "$SCRIPT_DIR/0-minio.yaml"
oc rollout status deployment/minio -n $LAB_PROJECT --timeout=120s

echo "[INFO] Creating S3 bucket..."
BUCKET="openvino-models"
oc exec deployment/minio -n $LAB_PROJECT -- mkdir -p /data/$BUCKET
echo "[INFO] Created bucket: $BUCKET"

# ── 3. S3 data connection ────────────────────────────────────────────────────

echo "[INFO] Creating S3 data connection..."
oc apply -f "$SCRIPT_DIR/1-data-connection.yaml"

# ── 4. Grant workbench SA access to secrets and routes ─────────────────────────

echo "[INFO] Granting workbench permissions..."
oc adm policy add-role-to-user admin user -n $LAB_PROJECT
for SA in default $WORKBENCH_NAME; do
  oc adm policy add-role-to-user view \
    system:serviceaccount:$LAB_PROJECT:$SA -n $LAB_PROJECT 2>/dev/null || true
done
oc create role secret-reader --verb=get,list --resource=secrets -n $LAB_PROJECT 2>/dev/null || true
for SA in default $WORKBENCH_NAME; do
  oc create rolebinding "${SA}-secret-reader" --role=secret-reader \
    --serviceaccount=$LAB_PROJECT:$SA -n $LAB_PROJECT 2>/dev/null || true
done

# ── 5. Workbench ─────────────────────────────────────────────────────────────

echo "[INFO] Creating workbench $WORKBENCH_NAME..."
oc apply -f "$SCRIPT_DIR/2-workbench.yaml"

echo "[INFO] Waiting for workbench pod (this may take a few minutes)..."
until oc get pod -n $LAB_PROJECT -l app=$WORKBENCH_NAME -o name 2>/dev/null | grep -q pod; do
  sleep 5
done
oc wait pod -n $LAB_PROJECT -l app=$WORKBENCH_NAME \
  --for=condition=Ready --timeout=600s

# ── 6. Clone exercise repo into workbench ─────────────────────────────────────

sleep 10
echo "[INFO] Cloning exercise repo into workbench..."
oc exec -n $LAB_PROJECT $WORKBENCH_NAME-0 -- \
  git clone -b RHAI3.4 https://github.com/RedHatTraining/ai-factory-apps.git \
  /opt/app-root/src/ai-factory-apps

echo "[OK] Setup complete. Open the RHOAI dashboard and navigate to the $LAB_PROJECT project."

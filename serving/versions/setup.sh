#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_PROJECT="serving-versions"
REGISTRY_NS="rhoai-model-registries"
REGISTRY_DIR="$SCRIPT_DIR/../registry"

command -v oc &>/dev/null  || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in. Run: oc login -u admin -p PASSWORD https://API_URL"; exit 1; }

# -- 1. MySQL + ModelRegistry ------------------------------------------------

echo "[INFO] Deploying MySQL and model registry..."
oc apply -f "$REGISTRY_DIR/1-deploy-mysqldb.yaml"
oc rollout status deployment/mysql -n $REGISTRY_NS --timeout=120s
oc apply -f "$REGISTRY_DIR/2-model-registry.yaml"

echo "[INFO] Waiting for model registry pod..."
oc wait pod -n $REGISTRY_NS -l app=model-registry-lab \
  --for=condition=Ready --timeout=180s

# -- 2. Lab project ----------------------------------------------------------

if ! oc project $LAB_PROJECT &>/dev/null; then
  echo "[INFO] Creating project $LAB_PROJECT..."
  oc new-project $LAB_PROJECT
else
  echo "[INFO] Project $LAB_PROJECT already exists, skipping."
fi

# -- 3. Permissions -----------------------------------------------------------

echo "[INFO] Granting user admin role in $LAB_PROJECT..."
oc adm policy add-role-to-user admin user -n $LAB_PROJECT

# -- 4. Scale dashboard (resource savings) ------------------------------------

echo "[INFO] Scaling rhods-dashboard to 1 replica..."
oc scale deployment rhods-dashboard -n redhat-ods-applications \
  --replicas=1 2>/dev/null || true

# -- 5. Build OCI model images on cluster -------------------------------------

echo "[INFO] Building OCI model images on cluster..."
for version in v1 v2; do
  tmpdir=$(mktemp -d)
  cp "$SCRIPT_DIR/Containerfile" "$tmpdir/Dockerfile"
  cp -r "$SCRIPT_DIR/models/$version/1" "$tmpdir/1"

  echo "[INFO] Building diabetes-$version image..."
  oc new-build --binary --name="diabetes-$version" --strategy=docker \
    -n $LAB_PROJECT 2>/dev/null || true
  oc start-build "diabetes-$version" --from-dir="$tmpdir" --follow \
    -n $LAB_PROJECT

  rm -rf "$tmpdir"
done

echo "[OK] Setup complete."

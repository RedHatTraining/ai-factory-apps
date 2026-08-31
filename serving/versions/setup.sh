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

# -- 4. Free cluster resources ------------------------------------------------

echo "[INFO] Scaling down non-essential workloads..."
oc scale deployment rhods-dashboard -n redhat-ods-applications \
  --replicas=1 2>/dev/null || true
oc scale deployment -n redhat-ods-applications \
  modelmesh-controller notebook-controller-deployment \
  data-science-pipelines-operator-controller-manager \
  feast-operator-controller-manager \
  kubeflow-trainer-controller-manager \
  kubeflow-training-operator \
  kuberay-operator \
  llama-stack-k8s-operator-controller-manager \
  llmisvc-controller-manager \
  trustyai-service-operator-controller-manager \
  odh-notebook-controller-manager \
  --replicas=0 2>/dev/null || true

# -- 5. Reduce default hardware profile resources -----------------------------

echo "[INFO] Patching default hardware profile for small models..."
oc patch hardwareprofile default-profile -n redhat-ods-applications --type json -p '[
  {"op":"replace","path":"/spec/identifiers/0/defaultCount","value":"500m"},
  {"op":"replace","path":"/spec/identifiers/0/maxCount","value":"1"},
  {"op":"replace","path":"/spec/identifiers/0/minCount","value":"100m"},
  {"op":"replace","path":"/spec/identifiers/1/defaultCount","value":"1Gi"},
  {"op":"replace","path":"/spec/identifiers/1/maxCount","value":"2Gi"},
  {"op":"replace","path":"/spec/identifiers/1/minCount","value":"256Mi"}
]' 2>/dev/null || true

# -- 6. Create pull secret for internal registry -------------------------------

echo "[INFO] Creating pull secret for internal registry..."
REGISTRY_HOST="image-registry.openshift-image-registry.svc:5000"
TOKEN=$(oc create token default -n $LAB_PROJECT --duration=24h)
AUTH=$(echo -n "unused:${TOKEN}" | base64 -w0)
DOCKERCFG="{\"auths\":{\"${REGISTRY_HOST}\":{\"auth\":\"${AUTH}\"}}}"

oc apply -f - <<EOF
apiVersion: v1
kind: Secret
type: kubernetes.io/dockerconfigjson
metadata:
  name: internal-registry
  namespace: $LAB_PROJECT
  labels:
    opendatahub.io/dashboard: "true"
  annotations:
    openshift.io/display-name: internal-registry
    opendatahub.io/connection-type-ref: "oci-v1"
stringData:
  ACCESS_TYPE: '["Pull"]'
  OCI_HOST: "${REGISTRY_HOST}"
  .dockerconfigjson: '${DOCKERCFG}'
EOF
oc secrets link default internal-registry --for=pull -n $LAB_PROJECT

# -- 7. OpenVINO Model Server runtime -----------------------------------------

echo "[INFO] Creating OpenVINO Model Server runtime..."
oc process -n redhat-ods-applications kserve-ovms | \
  oc apply -n $LAB_PROJECT -f -

# -- 8. Build OCI model images on cluster -------------------------------------

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

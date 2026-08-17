#!/bin/bash
set -euo pipefail

PROJECT="prepare-quantize"
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"

echo "[INFO] Verifying OpenShift login..."
oc whoami > /dev/null 2>&1 || { echo "[FAIL] Not logged in. Run: oc login ..."; exit 1; }
echo "[OK] Logged in as $(oc whoami)"

echo "[INFO] Creating project ${PROJECT}..."
oc new-project ${PROJECT} 2>/dev/null || oc project ${PROJECT}

oc label namespace ${PROJECT} \
    opendatahub.io/dashboard=true \
    modelmesh-enabled=false \
    --overwrite

echo "[INFO] Importing model images to internal registry..."
oc tag --source=docker quay.io/redhattraining/modelcar-qwen3-4b:bf16 \
    ${PROJECT}/modelcar-qwen3-4b:bf16 \
    --reference-policy=local

oc tag --source=docker quay.io/redhattraining/modelcar-qwen3-4b:fp8 \
    ${PROJECT}/modelcar-qwen3-4b:fp8 \
    --reference-policy=local

echo "[INFO] Pre-warming BF16 image on the node..."
IMAGE="${INTERNAL_REGISTRY}/${PROJECT}/modelcar-qwen3-4b:bf16"
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: prewarm-bf16
  namespace: ${PROJECT}
spec:
  containers:
  - name: pull
    image: ${IMAGE}
    command: ["true"]
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
EOF

oc wait --for=jsonpath='{.status.phase}'=Succeeded \
  pod/prewarm-bf16 -n ${PROJECT} --timeout=600s
oc delete pod prewarm-bf16 -n ${PROJECT}

echo "[INFO] Pre-warming FP8 fallback image on the node..."
IMAGE="${INTERNAL_REGISTRY}/${PROJECT}/modelcar-qwen3-4b:fp8"
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: prewarm-fp8
  namespace: ${PROJECT}
spec:
  containers:
  - name: pull
    image: ${IMAGE}
    command: ["true"]
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
EOF

oc wait --for=jsonpath='{.status.phase}'=Succeeded \
  pod/prewarm-fp8 -n ${PROJECT} --timeout=600s
oc delete pod prewarm-fp8 -n ${PROJECT}

echo "[INFO] Creating vLLM serving runtime..."
oc process vllm-cuda-runtime-template \
    -n redhat-ods-applications | oc apply -n ${PROJECT} -f -

oc annotate servingruntime vllm-cuda-runtime -n ${PROJECT} \
    opendatahub.io/template-name=vllm-cuda-runtime-template \
    opendatahub.io/template-display-name="vLLM NVIDIA GPU ServingRuntime for KServe" \
    opendatahub.io/apiProtocol=REST

echo ""
echo "[OK] Setup complete."
echo "[INFO] Verify: oc get servingruntime -n ${PROJECT}"
echo "[INFO] Verify: oc get imagestreamtags -n ${PROJECT} | grep qwen3-4b"

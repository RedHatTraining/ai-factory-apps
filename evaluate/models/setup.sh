#!/usr/bin/env bash
#
# setup.sh — Prepare the cluster for the model evaluation exercise.
#
# Automates the instructor/setup steps that must run BEFORE students begin:
#
#   1. Create and label the exercise namespace
#   2. Create the vLLM CUDA ServingRuntime from the RHOAI template
#   3. Pre-cache the Qwen3-8B-FP8-dynamic OCI image into the internal
#      registry and pre-warm the GPU node's image cache
#
# The image pre-cache (step 3) is best-effort: if it fails or is slow, setup
# continues and reports a warning — the essential namespace and ServingRuntime
# are still provisioned. Without the pre-cache the exercise still works; the
# model deployment just performs a slower cold pull.
#
# This script MUTATES the cluster. Run it as cluster-admin.
# Re-running is safe (idempotent): existing resources are reused, not duplicated.
#
# Usage:
#   bash setup.sh
#
# Environment overrides (raise these on slow lab environments):
#   OC_REQUEST_TIMEOUT   Per-call oc request cap        (default 30s)
#   ISTAG_TIMEOUT        Wait for image import (s)       (default 300)
#   PREWARM_TIMEOUT      Wait for node pre-warm (s)      (default 600)
#   POLL_INTERVAL        Poll interval for loops (s)     (default 5)
#

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()     { echo -e "  ${GREEN}✓${NC} $*"; }
warn()   { echo -e "  ${YELLOW}!${NC} $*"; }
info()   { echo -e "  ${CYAN}→${NC} $*"; }
header() { echo -e "\n${BOLD}$*${NC}"; }
die()    { echo -e "\n${RED}${BOLD}✗ $*${NC}\n"; exit 1; }

OC_REQUEST_TIMEOUT="${OC_REQUEST_TIMEOUT:-30s}"
oc() {
  if [[ "${1:-}" == "wait" ]]; then
    command oc "$@"
  else
    command oc --request-timeout="$OC_REQUEST_TIMEOUT" "$@"
  fi
}

# --- Exercise constants -------------------------------------------------------
NAMESPACE="evaluate-models"
RHOAI_NS="redhat-ods-applications"
RUNTIME_TEMPLATE="vllm-cuda-runtime-template"
SERVING_RUNTIME="vllm-cuda-runtime"
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"

MODEL_IMAGE="registry.redhat.io/rhelai1/modelcar-qwen3-8b-fp8-dynamic:1.5"
ISTAG="modelcar-qwen3-8b:latest"

# Timeouts (seconds)
ISTAG_TIMEOUT="${ISTAG_TIMEOUT:-300}"
PREWARM_TIMEOUT="${PREWARM_TIMEOUT:-600}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-6}"
RETRY_DELAY="${RETRY_DELAY:-10}"
DEGRADED=0

attempts_for() {
  local n=$(( $1 / POLL_INTERVAL ))
  [[ "$n" -lt 1 ]] && n=1
  echo "$n"
}

retry_cmd() {
  local attempts="$1" delay="$2"; shift 2
  local i=1
  while true; do
    "$@" && return 0
    [[ "$i" -ge "$attempts" ]] && return 1
    sleep "$delay"
    i=$(( i + 1 ))
  done
}

wait_pod_complete() {
  local pod="$1" ns="$2" timeout="$3"
  local phase reason
  for _ in $(seq 1 "$(attempts_for "$timeout")"); do
    phase=$(oc get pod "$pod" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    case "$phase" in
      Succeeded) return 0 ;;
      Failed)    return 1 ;;
    esac
    reason=$(oc get pod "$pod" -n "$ns" \
      -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
    case "$reason" in
      ImagePullBackOff|InvalidImageName) return 1 ;;
    esac
    sleep "$POLL_INTERVAL"
  done
  return 1
}

echo ""
echo -e "${BOLD}Evaluate Models Exercise — Setup${NC}"
echo "Preparing namespace, runtime, and model image"

# --- Preconditions ------------------------------------------------------------
if ! oc whoami &>/dev/null; then
  die "Not logged in to the cluster. Run: oc login -u <admin> -p <password> <api-url>"
fi
if ! oc auth can-i '*' '*' --all-namespaces &>/dev/null; then
  die "Current user ($(command oc whoami 2>/dev/null)) is not cluster-admin. Log in as a cluster-admin user."
fi
ok "Logged in as $(oc whoami) with cluster-admin privileges"

###############################################################################
header "1. Namespace"
###############################################################################

if oc get namespace "$NAMESPACE" &>/dev/null; then
  info "Namespace '$NAMESPACE' already exists — reusing it"
else
  oc new-project "$NAMESPACE" >/dev/null || die "Failed to create namespace '$NAMESPACE'"
  ok "Created namespace '$NAMESPACE'"
fi

retry_cmd "$RETRY_ATTEMPTS" "$RETRY_DELAY" \
  oc label namespace "$NAMESPACE" \
    opendatahub.io/dashboard=true \
    modelmesh-enabled=false \
    --overwrite >/dev/null \
  || die "Failed to label namespace '$NAMESPACE'"
ok "Labeled namespace (opendatahub.io/dashboard=true, modelmesh-enabled=false)"

###############################################################################
header "2. Patch GPU Hardware Profile"
###############################################################################

HP_NAME="gpu-profile"
HP_MEM_DEFAULT="16Gi"
HP_MEM_MAX="24Gi"

if oc get hardwareprofile "$HP_NAME" -n "$RHOAI_NS" &>/dev/null; then
  if retry_cmd "$RETRY_ATTEMPTS" "$RETRY_DELAY" \
    oc patch hardwareprofile "$HP_NAME" -n "$RHOAI_NS" --type='json' -p="[
      {\"op\": \"replace\", \"path\": \"/spec/identifiers/1/defaultCount\", \"value\": \"${HP_MEM_DEFAULT}\"},
      {\"op\": \"replace\", \"path\": \"/spec/identifiers/1/maxCount\", \"value\": \"${HP_MEM_MAX}\"}
    ]" >/dev/null 2>&1; then
    ok "Patched '$HP_NAME' memory: default=${HP_MEM_DEFAULT}, max=${HP_MEM_MAX}"
  else
    warn "Failed to patch '$HP_NAME' — model deployment may fail with OOM"
    DEGRADED=1
  fi
else
  warn "HardwareProfile '$HP_NAME' not found in $RHOAI_NS — skipping patch"
  DEGRADED=1
fi

###############################################################################
header "3. Create vLLM ServingRuntime"
###############################################################################

if ! retry_cmd "$RETRY_ATTEMPTS" "$RETRY_DELAY" \
     oc get template "$RUNTIME_TEMPLATE" -n "$RHOAI_NS" &>/dev/null; then
  die "Template '$RUNTIME_TEMPLATE' not found in $RHOAI_NS after ${RETRY_ATTEMPTS} attempts — is RHOAI/KServe installed?"
fi

apply_serving_runtime() {
  oc process "$RUNTIME_TEMPLATE" -n "$RHOAI_NS" \
    | oc apply -n "$NAMESPACE" -f - >/dev/null 2>&1
}
if retry_cmd "$RETRY_ATTEMPTS" "$RETRY_DELAY" apply_serving_runtime; then
  ok "Applied ServingRuntime '$SERVING_RUNTIME' in $NAMESPACE"
else
  die "Failed to create ServingRuntime from template after ${RETRY_ATTEMPTS} attempts"
fi

###############################################################################
header "4. Pre-cache Model Image (best-effort)"
###############################################################################

if oc tag --source=docker "$MODEL_IMAGE" "${NAMESPACE}/${ISTAG}" \
     --reference-policy=local >/dev/null 2>&1; then
  ok "Tagged ${MODEL_IMAGE} -> ${NAMESPACE}/${ISTAG}"
else
  warn "Failed to tag ${MODEL_IMAGE} (deployment will cold-pull from quay.io)"
  DEGRADED=1
fi

if [[ "$DEGRADED" -eq 0 ]]; then
  info "Waiting for ${ISTAG} to import (up to ${ISTAG_TIMEOUT}s)..."
  IMPORTED=""
  for _ in $(seq 1 "$(attempts_for "$ISTAG_TIMEOUT")"); do
    IMPORTED=$(oc get istag "$ISTAG" -n "$NAMESPACE" \
      -o jsonpath='{.image.metadata.name}' 2>/dev/null || echo "")
    [[ -n "$IMPORTED" ]] && break
    sleep "$POLL_INTERVAL"
  done

  if [[ -n "$IMPORTED" ]]; then
    ok "Imported ${ISTAG} manifest"
  else
    warn "${ISTAG} did not import within ${ISTAG_TIMEOUT}s"
    echo -e "     ${CYAN}Check:${NC} oc describe istag ${ISTAG} -n ${NAMESPACE}"
    DEGRADED=1
  fi
fi

###############################################################################
header "5. Pre-warm GPU Node Image Cache (best-effort)"
###############################################################################

if [[ "$DEGRADED" -eq 1 ]]; then
  warn "Image import incomplete — skipping node pre-warm"
else
  POD_NAME="prewarm-qwen3-8b"
  IMAGE="${INTERNAL_REGISTRY}/${NAMESPACE}/${ISTAG}"

  oc delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1

  if cat <<EOF | oc apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
spec:
  containers:
  - name: pull
    image: ${IMAGE}
    command: ["true"]
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  nodeSelector:
    node-role.kubernetes.io/worker-gpu: ""
EOF
  then
    info "Pre-warming ${ISTAG} on the node (up to ${PREWARM_TIMEOUT}s)..."
    if wait_pod_complete "$POD_NAME" "$NAMESPACE" "$PREWARM_TIMEOUT"; then
      ok "Pre-warmed ${ISTAG} (cached on the GPU node)"
    else
      warn "Pre-warm did not complete for ${ISTAG}"
      echo -e "     ${CYAN}Check:${NC} oc describe pod ${POD_NAME} -n ${NAMESPACE}"
      DEGRADED=1
    fi
  else
    warn "Failed to create pre-warm pod"
    DEGRADED=1
  fi

  oc delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
fi

###############################################################################
header "6. Validate Setup"
###############################################################################

if oc get servingruntime "$SERVING_RUNTIME" -n "$NAMESPACE" &>/dev/null; then
  ok "ServingRuntime '$SERVING_RUNTIME' present"
else
  die "ServingRuntime '$SERVING_RUNTIME' not found after apply"
fi

if oc get istag "$ISTAG" -n "$NAMESPACE" &>/dev/null; then
  ok "Imagestream tag '$ISTAG' present"
else
  warn "Imagestream tag '$ISTAG' not present (deployment will cold-pull from quay.io)"
  DEGRADED=1
fi

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ "$DEGRADED" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}Setup complete — the environment is ready for the exercise.${NC}"
else
  echo -e "${YELLOW}${BOLD}Setup finished with warnings.${NC}"
  echo -e "${CYAN}The namespace and vLLM runtime are ready; the image pre-cache${NC}"
  echo -e "${CYAN}may be unavailable, so the model deployment will cold-pull. Review above.${NC}"
fi
echo ""

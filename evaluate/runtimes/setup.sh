#!/usr/bin/env bash
#
# setup.sh — Prepare the cluster for the Evaluate Runtimes exercise.
#
# Automates the instructor/setup steps that must run BEFORE students begin:
#
#   1. Create and label the exercise namespace
#   2. Import the model image into the internal registry
#   3. Pre-warm the GPU node's image cache with a short-lived pull pod
#   4. Create the vLLM ServingRuntime from the RHOAI template
#
# This script MUTATES the cluster. Run it as cluster-admin.
# Re-running is safe (idempotent): existing resources are reused, not duplicated.
#
# The image pre-warm step (step 3) is best-effort: if it fails or is slow,
# setup continues and reports a warning — the essential runtime is still
# provisioned.
#
# Usage:
#   bash setup.sh
#
# Environment overrides (raise these on slow lab environments):
#   OC_REQUEST_TIMEOUT   Per-call oc request cap        (default 30s)
#   ISTAG_TIMEOUT        Wait for image import (s)      (default 300)
#   PREWARM_TIMEOUT      Wait for node pre-warm (s)     (default 600)
#   POLL_INTERVAL        Poll interval for loops (s)    (default 5)
#
# Works on macOS and Linux (bash 3.2+). Uses no GNU-only tools.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
NAMESPACE="evaluate-runtimes"
RHOAI_NS="redhat-ods-applications"
RUNTIME_TEMPLATE="vllm-cuda-runtime-template"
SERVING_RUNTIME="vllm-cuda-runtime"
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"

MODEL_SRC="quay.io/redhattraining/modelcar-qwen3-06b:v1"
MODEL_ISTAG="modelcar-qwen3-06b:v1"
MODEL_INTERNAL_IMAGE="${INTERNAL_REGISTRY}/${NAMESPACE}/${MODEL_ISTAG}"

ISTAG_TIMEOUT="${ISTAG_TIMEOUT:-300}"
PREWARM_TIMEOUT="${PREWARM_TIMEOUT:-600}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

HARDWARE_PROFILE_NAME="gpu-profile"

DEGRADED=0

RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-6}"
RETRY_DELAY="${RETRY_DELAY:-10}"

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
echo -e "${BOLD}Evaluate Runtimes Exercise — Setup${NC}"
echo "Preparing namespace, model image, and vLLM runtime"

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
  oc new-project "$NAMESPACE" --skip-config-write >/dev/null || die "Failed to create namespace '$NAMESPACE'"
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
header "2. GPU Hardware Profile"
###############################################################################

if cat <<EOF | oc apply -f - >/dev/null 2>&1
apiVersion: infrastructure.opendatahub.io/v1
kind: HardwareProfile
metadata:
  name: ${HARDWARE_PROFILE_NAME}
  namespace: ${RHOAI_NS}
  annotations:
    opendatahub.io/dashboard-feature-visibility: '[]'
    opendatahub.io/disabled: "false"
    opendatahub.io/display-name: gpu-profile
spec:
  identifiers:
  - defaultCount: 500m
    displayName: CPU
    identifier: cpu
    maxCount: 4
    minCount: 100m
    resourceType: CPU
  - defaultCount: 8Gi
    displayName: Memory
    identifier: memory
    maxCount: 12Gi
    minCount: 1Gi
    resourceType: Memory
  - defaultCount: 1
    displayName: GPU
    identifier: nvidia.com/gpu
    maxCount: 1
    minCount: 1
    resourceType: Accelerator
  scheduling:
    type: Node
    node:
      tolerations:
      - key: nvidia.com/gpu
        operator: Equal
        value: "true"
        effect: NoSchedule
EOF
then
  ok "Applied HardwareProfile '${HARDWARE_PROFILE_NAME}' with GPU toleration"
else
  die "Failed to create HardwareProfile '${HARDWARE_PROFILE_NAME}'"
fi

###############################################################################
header "3. Import Model Image (best-effort)"
###############################################################################

MODEL_READY=false

if oc tag --source=docker "$MODEL_SRC" \
     "${NAMESPACE}/${MODEL_ISTAG}" \
     --reference-policy=local >/dev/null 2>&1; then
  ok "Tagged $MODEL_SRC -> ${NAMESPACE}/${MODEL_ISTAG}"

  info "Waiting for image to import (up to ${ISTAG_TIMEOUT}s)..."
  imported=""
  for _ in $(seq 1 "$(attempts_for "$ISTAG_TIMEOUT")"); do
    imported=$(oc get istag "$MODEL_ISTAG" -n "$NAMESPACE" \
      -o jsonpath='{.image.metadata.name}' 2>/dev/null || echo "")
    [[ -n "$imported" ]] && break
    sleep "$POLL_INTERVAL"
  done

  if [[ -n "$imported" ]]; then
    ok "Model image manifest imported"
    MODEL_READY=true
  else
    warn "Model image did not import within ${ISTAG_TIMEOUT}s"
    echo -e "     ${CYAN}Check:${NC} oc describe istag ${MODEL_ISTAG} -n ${NAMESPACE}"
    DEGRADED=1
  fi
else
  warn "Failed to tag the model image (skipping)"
  DEGRADED=1
fi

###############################################################################
header "4. Pre-warm GPU Node Image Cache (best-effort)"
###############################################################################

PREWARM_POD="prewarm-model"

if [[ "$MODEL_READY" == "true" ]]; then
  oc delete pod "$PREWARM_POD" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1

  if cat <<EOF | oc apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: ${PREWARM_POD}
  namespace: ${NAMESPACE}
spec:
  containers:
  - name: pull
    image: ${MODEL_INTERNAL_IMAGE}
    command: ["true"]
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  tolerations:
  - key: nvidia.com/gpu
    operator: Equal
    value: "true"
    effect: NoSchedule
  nodeSelector:
    node-role.kubernetes.io/worker-gpu: ""
EOF
  then
    ok "Created pre-warm pod '${PREWARM_POD}'"
    info "Waiting for it to pull the image and complete (up to ${PREWARM_TIMEOUT}s)..."
    if wait_pod_complete "$PREWARM_POD" "$NAMESPACE" "$PREWARM_TIMEOUT"; then
      ok "Pre-warm pod completed — image is cached on the node"
    else
      PHASE=$(oc get pod "$PREWARM_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
      REASON=$(oc get pod "$PREWARM_POD" -n "$NAMESPACE" \
        -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
      warn "Pre-warm pod did not complete (phase='${PHASE}'${REASON:+, reason='${REASON}'})"
      echo -e "     ${CYAN}Check:${NC} oc describe pod ${PREWARM_POD} -n ${NAMESPACE}"
      DEGRADED=1
    fi
    oc delete pod "$PREWARM_POD" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  else
    warn "Failed to create the pre-warm pod"
    DEGRADED=1
  fi
else
  warn "Skipping node pre-warm — image is not available"
  DEGRADED=1
fi

###############################################################################
header "5. Create vLLM ServingRuntime"
###############################################################################

TEMPLATE_ERR=""
check_template() { TEMPLATE_ERR=$(oc get template "$RUNTIME_TEMPLATE" -n "$RHOAI_NS" 2>&1 >/dev/null); }
if ! retry_cmd "$RETRY_ATTEMPTS" "$RETRY_DELAY" check_template; then
  case "$TEMPLATE_ERR" in
    *NotFound*|*"not found"*)
      die "Template '$RUNTIME_TEMPLATE' not found in $RHOAI_NS — is RHOAI/KServe installed?
     Check: oc get template -n $RHOAI_NS | grep vllm" ;;
    *)
      die "Could not read template '$RUNTIME_TEMPLATE' in $RHOAI_NS after ${RETRY_ATTEMPTS} attempts.
     Last error: ${TEMPLATE_ERR}
     Tip: re-run setup.sh, or raise the retry budget: RETRY_ATTEMPTS=12 bash setup.sh" ;;
  esac
fi
ok "Template '$RUNTIME_TEMPLATE' found in $RHOAI_NS"

apply_serving_runtime() {
  oc process "$RUNTIME_TEMPLATE" -n "$RHOAI_NS" \
    | oc apply -n "$NAMESPACE" -f - >/dev/null 2>&1
}
if retry_cmd "$RETRY_ATTEMPTS" "$RETRY_DELAY" apply_serving_runtime; then
  ok "Applied ServingRuntime '$SERVING_RUNTIME' in $NAMESPACE"
else
  die "Failed to create ServingRuntime from template after ${RETRY_ATTEMPTS} attempts"
fi

retry_cmd "$RETRY_ATTEMPTS" "$RETRY_DELAY" \
  oc annotate servingruntime "$SERVING_RUNTIME" -n "$NAMESPACE" \
    opendatahub.io/template-name=vllm-cuda-runtime-template \
    opendatahub.io/template-display-name="vLLM NVIDIA GPU ServingRuntime for KServe" \
    opendatahub.io/apiProtocol=REST \
    --overwrite >/dev/null \
  || warn "Failed to annotate ServingRuntime (non-fatal)"

ok "Annotated ServingRuntime with template metadata and apiProtocol"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ "$DEGRADED" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}Setup complete — the environment is ready for the exercise.${NC}"
else
  echo -e "${YELLOW}${BOLD}Setup finished with warnings.${NC}"
  echo -e "${CYAN}The vLLM runtime is ready; the optional image pre-warm step${NC}"
  echo -e "${CYAN}may be incomplete. Review the warnings above.${NC}"
fi
echo ""

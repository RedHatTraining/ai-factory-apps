#!/usr/bin/env bash
#
# setup.sh — Prepare the cluster for the Quantize exercise.
#
# Automates the instructor/setup steps that must run BEFORE students begin:
#
#   1. Create and label the exercise namespace
#   2. Import BF16 and FP8 model images into the internal registry
#   3. Pre-warm the GPU node's image cache with short-lived pull pods
#   4. Create the GPU hardware profile from gpu-profile.yaml
#   5. Create the vLLM ServingRuntime from the RHOAI template and annotate it
#
# This script MUTATES the cluster. Run it as cluster-admin.
# Re-running is safe (idempotent): existing resources are reused, not duplicated.
#
# The image pre-warm steps (step 3) are best-effort: if they fail or are slow,
# setup continues and reports a warning — the essential runtime and hardware
# profile are still provisioned.
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

# Cap each oc request so a slow/unreachable API fails fast instead of hanging.
# `oc wait` is exempt: it runs a long watch bounded by its own --timeout, which
# a short per-request cap would break. `command oc` avoids recursing here.
OC_REQUEST_TIMEOUT="${OC_REQUEST_TIMEOUT:-30s}"
oc() {
  if [[ "${1:-}" == "wait" ]]; then
    command oc "$@"
  else
    command oc --request-timeout="$OC_REQUEST_TIMEOUT" "$@"
  fi
}

# --- Exercise constants -------------------------------------------------------
NAMESPACE="prepare-quantize"
RHOAI_NS="redhat-ods-applications"
RUNTIME_TEMPLATE="vllm-cuda-runtime-template"
SERVING_RUNTIME="vllm-cuda-runtime"
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"

# Model images to import and pre-warm.
BF16_SRC="quay.io/redhattraining/modelcar-qwen3-4b:bf16"
BF16_ISTAG="modelcar-qwen3-4b:bf16"
BF16_INTERNAL_IMAGE="${INTERNAL_REGISTRY}/${NAMESPACE}/${BF16_ISTAG}"

FP8_SRC="quay.io/redhattraining/modelcar-qwen3-4b:fp8"
FP8_ISTAG="modelcar-qwen3-4b:fp8"
FP8_INTERNAL_IMAGE="${INTERNAL_REGISTRY}/${NAMESPACE}/${FP8_ISTAG}"

# Timeouts (seconds) — override via env for slow lab environments.
ISTAG_TIMEOUT="${ISTAG_TIMEOUT:-300}"
PREWARM_TIMEOUT="${PREWARM_TIMEOUT:-600}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

DEGRADED=0  # tracks non-fatal (best-effort) issues for the final summary

# Retries for critical one-shot API calls. The aggregated openshift-apiserver
# can briefly go unavailable during a rollout; a single call may fail
# transiently. Retrying rides that out.
RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-6}"
RETRY_DELAY="${RETRY_DELAY:-10}"

# attempts_for <total_seconds> — how many POLL_INTERVAL slices fit in a timeout.
attempts_for() {
  local n=$(( $1 / POLL_INTERVAL ))
  [[ "$n" -lt 1 ]] && n=1
  echo "$n"
}

# retry_cmd <attempts> <delay> <cmd...> — run cmd until it succeeds or the
# attempts are exhausted, sleeping <delay> seconds between tries.
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

# wait_pod_complete <pod> <ns> <timeout_seconds> — block until the pod reaches
# Succeeded (0), or fail (1) on Failed / an unrecoverable image-pull error /
# timeout. Unlike `oc wait --for=Succeeded`, this bails in seconds on a bad pull
# instead of blocking for the whole timeout, so setup never looks hung.
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
echo -e "${BOLD}Quantize Exercise — Setup${NC}"
echo "Preparing namespace, model images, GPU profile, and vLLM runtime"

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
header "2. Import Model Images (best-effort)"
###############################################################################

# import_image <src> <istag> — tag + wait for import; sets <TAG>_READY=true on
# success, marks DEGRADED on failure.
BF16_READY=false
FP8_READY=false

import_image() {
  local src="$1" istag="$2" label="$3"
  if oc tag --source=docker "$src" \
       "${NAMESPACE}/${istag}" \
       --reference-policy=local >/dev/null 2>&1; then
    ok "Tagged $src -> ${NAMESPACE}/${istag}"

    info "Waiting for ${label} image to import (up to ${ISTAG_TIMEOUT}s)..."
    local imported=""
    for _ in $(seq 1 "$(attempts_for "$ISTAG_TIMEOUT")"); do
      imported=$(oc get istag "$istag" -n "$NAMESPACE" \
        -o jsonpath='{.image.metadata.name}' 2>/dev/null || echo "")
      [[ -n "$imported" ]] && break
      sleep "$POLL_INTERVAL"
    done

    if [[ -n "$imported" ]]; then
      ok "${label} image manifest imported"
      return 0
    else
      warn "${label} image did not import within ${ISTAG_TIMEOUT}s"
      echo -e "     ${CYAN}Check:${NC} oc describe istag ${istag} -n ${NAMESPACE}"
      DEGRADED=1
      return 1
    fi
  else
    warn "Failed to tag the ${label} image (skipping)"
    DEGRADED=1
    return 1
  fi
}

import_image "$BF16_SRC" "$BF16_ISTAG" "BF16" && BF16_READY=true
import_image "$FP8_SRC" "$FP8_ISTAG" "FP8" && FP8_READY=true

###############################################################################
header "3. Pre-warm GPU Node Image Cache (best-effort)"
###############################################################################

# prewarm_image <pod_name> <internal_image> <label> — create a short-lived pod
# to pull the image so it is cached on the node, then clean it up.
prewarm_image() {
  local pod_name="$1" image="$2" label="$3"

  oc delete pod "$pod_name" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1

  if cat <<EOF | oc apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${NAMESPACE}
spec:
  containers:
  - name: pull
    image: ${image}
    command: ["true"]
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
EOF
  then
    ok "Created ${label} pre-warm pod '${pod_name}'"
    info "Waiting for it to pull the image and complete (up to ${PREWARM_TIMEOUT}s)..."
    if wait_pod_complete "$pod_name" "$NAMESPACE" "$PREWARM_TIMEOUT"; then
      ok "${label} pre-warm pod completed — image is cached on the node"
    else
      PHASE=$(oc get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
      REASON=$(oc get pod "$pod_name" -n "$NAMESPACE" \
        -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
      warn "${label} pre-warm pod did not complete (phase='${PHASE}'${REASON:+, reason='${REASON}'})"
      echo -e "     ${CYAN}Check:${NC} oc describe pod ${pod_name} -n ${NAMESPACE}"
      DEGRADED=1
    fi
    oc delete pod "$pod_name" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  else
    warn "Failed to create the ${label} pre-warm pod"
    DEGRADED=1
  fi
}

if [[ "$BF16_READY" == "true" ]]; then
  prewarm_image "prewarm-bf16" "$BF16_INTERNAL_IMAGE" "BF16"
else
  warn "Skipping BF16 node pre-warm — image is not available"
  DEGRADED=1
fi

if [[ "$FP8_READY" == "true" ]]; then
  prewarm_image "prewarm-fp8" "$FP8_INTERNAL_IMAGE" "FP8"
else
  warn "Skipping FP8 node pre-warm — image is not available"
  DEGRADED=1
fi

###############################################################################
header "4. GPU Hardware Profile"
###############################################################################

if oc get hardwareprofile gpu-profile -n "$RHOAI_NS" &>/dev/null; then
  info "Hardware profile 'gpu-profile' already exists — updating it"
else
  info "Creating GPU hardware profile"
fi

if oc apply -f "${SCRIPT_DIR}/gpu-profile.yaml" >/dev/null 2>&1; then
  ok "Applied GPU hardware profile from gpu-profile.yaml"
else
  die "Failed to apply gpu-profile.yaml"
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
  echo -e "${CYAN}The vLLM runtime and GPU profile are ready; the optional image${NC}"
  echo -e "${CYAN}pre-warm steps may be incomplete. Review the warnings above.${NC}"
fi
echo ""

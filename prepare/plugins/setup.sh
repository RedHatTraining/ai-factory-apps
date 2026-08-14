#!/usr/bin/env bash
#
# setup.sh — Prepare the cluster for the vLLM plugins exercise.
#
# Automates the instructor/setup steps that must run BEFORE students begin
# (everything above "Exercise starts here" in the exercise guide):
#
#   1. Create and label the exercise namespace
#   2. Ensure the internal image registry is Managed (running)
#   3. Pre-cache BOTH exercise images into the internal registry:
#        - the custom-architecture ModelCar image (the "unsupported" model)
#        - the custom vLLM runtime image (base vLLM + the plugin pip package)
#   4. Pre-warm the GPU node's image cache for both images
#   5. Create the standard vLLM ServingRuntime from the RHOAI template
#   6. Validate the setup
#
# Unlike the ModelCar exercise, students here CONSUME pre-built images (they do
# not build or push anything), so this script needs no external registry route
# and no Podman — all image movement is cluster-internal (pull-through import
# with `oc tag --reference-policy=local` + in-cluster pre-warm pulls).
#
# This script MUTATES the cluster. Run it as cluster-admin.
# Re-running is safe (idempotent): existing resources are reused, not duplicated.
#
# The image pre-cache (steps 3-4) is best-effort: if it fails or is slow, setup
# continues and reports a warning — the essential namespace and ServingRuntime
# are still provisioned. Without the pre-cache the exercise still works; the
# affected deployment just performs a slower cold pull the first time.
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
# Works on macOS and Linux (bash 3.2+). Uses no GNU-only tools.
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
NAMESPACE="prepare-plugins"
RHOAI_NS="redhat-ods-applications"
RUNTIME_TEMPLATE="vllm-cuda-runtime-template"
SERVING_RUNTIME="vllm-cuda-runtime"
REGISTRY_CONFIG="configs.imageregistry.operator.openshift.io/cluster"
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"

# The two images the exercise consumes, each pre-imported into the internal
# registry as a local-reference imagestream tag. Format: "SRC|ISTAG".
#   - the custom-architecture ModelCar (config.json => CustomQwen3ForCausalLM)
#   - the custom vLLM runtime (base vLLM image + the custom-qwen3-plugin package)
IMAGES=(
  "quay.io/redhattraining/modelcar-qwen3-06b-custom:v1|modelcar-qwen3-06b-custom:v1"
  "quay.io/redhattraining/vllm-custom-qwen3:3.4.0|vllm-custom-qwen3:3.4.0"
)

# Timeouts (seconds) — override via env for slow lab environments.
ISTAG_TIMEOUT="${ISTAG_TIMEOUT:-300}"
PREWARM_TIMEOUT="${PREWARM_TIMEOUT:-600}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

DEGRADED=0  # tracks non-fatal (best-effort) issues for the final summary

# Retries for critical one-shot API calls. The aggregated openshift-apiserver
# (templates, imagestreams) can briefly go unavailable during a rollout;
# combined with the per-request cap above, a single call may fail transiently.
# Retrying rides that out. Defaults span ~60s — enough for an apiserver rollout.
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
    # ImagePullBackOff means the kubelet already tried and is backing off — a
    # slow-but-progressing pull shows Pulling/ContainerCreating, not this.
    reason=$(oc get pod "$pod" -n "$ns" \
      -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
    case "$reason" in
      ImagePullBackOff|InvalidImageName) return 1 ;;
    esac
    sleep "$POLL_INTERVAL"
  done
  return 1
}

# import_image <src> <istag> — pull-through import an external image into the
# internal registry as a local-reference imagestream tag, then wait until the
# async import resolves to a real manifest. Returns 0 on success, 1 otherwise.
import_image() {
  local src="$1" istag="$2"
  if ! oc tag --source=docker "$src" "${NAMESPACE}/${istag}" \
       --reference-policy=local >/dev/null 2>&1; then
    warn "Failed to tag ${src} (skipping)"
    return 1
  fi
  ok "Tagged ${src} -> ${NAMESPACE}/${istag}"

  info "Waiting for ${istag} to import (up to ${ISTAG_TIMEOUT}s)..."
  local imported=""
  for _ in $(seq 1 "$(attempts_for "$ISTAG_TIMEOUT")"); do
    imported=$(oc get istag "$istag" -n "$NAMESPACE" \
      -o jsonpath='{.image.metadata.name}' 2>/dev/null || echo "")
    [[ -n "$imported" ]] && break
    sleep "$POLL_INTERVAL"
  done

  if [[ -n "$imported" ]]; then
    ok "Imported ${istag} manifest (layers cached by the pre-warm step)"
    return 0
  fi
  warn "${istag} did not import within ${ISTAG_TIMEOUT}s"
  echo -e "     ${CYAN}Why:${NC} the cluster may not be able to pull from quay.io"
  echo -e "     ${CYAN}Check:${NC} oc describe istag ${istag} -n ${NAMESPACE}"
  return 1
}

# prewarm_image <istag> — run a short-lived pod that pulls the internal image so
# it is cached on the GPU node, making the exercise deployment start quickly.
# Best-effort: any failure is a warning, never fatal.
prewarm_image() {
  local istag="$1"
  local pod="prewarm-${istag%%:*}"          # strip the ":tag" for a valid pod name
  local image="${INTERNAL_REGISTRY}/${NAMESPACE}/${istag}"

  oc delete pod "$pod" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1

  if ! cat <<EOF | oc apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
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
    warn "Failed to create pre-warm pod for ${istag}"
    return 1
  fi

  info "Pre-warming ${istag} on the node (up to ${PREWARM_TIMEOUT}s)..."
  local rc=0
  if wait_pod_complete "$pod" "$NAMESPACE" "$PREWARM_TIMEOUT"; then
    ok "Pre-warmed ${istag} (cached on the GPU node)"
  else
    warn "Pre-warm did not complete for ${istag}"
    echo -e "     ${CYAN}Check:${NC} oc describe pod ${pod} -n ${NAMESPACE}"
    rc=1
  fi
  # Always remove the pre-warm pod so students never see a dangling pod.
  oc delete pod "$pod" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  return "$rc"
}

echo ""
echo -e "${BOLD}vLLM Plugins Exercise — Setup${NC}"
echo "Preparing namespace, pre-cached images, and the vLLM runtime"

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
header "2. Internal Image Registry"
###############################################################################

# The registry must be Managed (running) so the pull-through import and the
# in-cluster pre-warm pulls work. Unlike the ModelCar exercise, no external
# route is needed: students never push, they only consume internal images.
REG_STATE=$(oc get "$REGISTRY_CONFIG" -o jsonpath='{.spec.managementState}' 2>/dev/null || echo "")
if [[ "$REG_STATE" == "Managed" ]]; then
  ok "Internal image registry is Managed"
else
  if retry_cmd "$RETRY_ATTEMPTS" "$RETRY_DELAY" \
       oc patch "$REGISTRY_CONFIG" --type merge \
         -p '{"spec":{"managementState":"Managed"}}' >/dev/null; then
    ok "Set internal image registry managementState to Managed"
  else
    die "Failed to set the internal image registry to Managed"
  fi
fi

###############################################################################
header "3. Pre-cache Exercise Images (best-effort)"
###############################################################################

# Import both images first, then pre-warm the ones that imported. Splitting the
# loops means an import failure for one image never blocks pre-warming the other.
PREWARM_LIST=()
for entry in "${IMAGES[@]}"; do
  SRC="${entry%%|*}"
  ISTAG="${entry##*|}"
  if import_image "$SRC" "$ISTAG"; then
    PREWARM_LIST+=("$ISTAG")
  else
    DEGRADED=1
  fi
done

###############################################################################
header "4. Pre-warm GPU Node Image Cache (best-effort)"
###############################################################################

if [[ "${#PREWARM_LIST[@]}" -eq 0 ]]; then
  warn "No images imported — skipping node pre-warm"
  DEGRADED=1
else
  for istag in "${PREWARM_LIST[@]}"; do
    prewarm_image "$istag" || DEGRADED=1
  done
fi

###############################################################################
header "5. Create vLLM ServingRuntime"
###############################################################################

# The standard runtime is used in the first (failing) deployment. Students
# create the custom runtime themselves later in the exercise.
if ! retry_cmd "$RETRY_ATTEMPTS" "$RETRY_DELAY" \
     oc get template "$RUNTIME_TEMPLATE" -n "$RHOAI_NS" &>/dev/null; then
  die "Template '$RUNTIME_TEMPLATE' not found in $RHOAI_NS after ${RETRY_ATTEMPTS} attempts — is RHOAI/KServe installed?"
fi

# process | apply is retried as a unit (both go through the aggregated apiserver).
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
header "6. Validate Setup"
###############################################################################

if oc get servingruntime "$SERVING_RUNTIME" -n "$NAMESPACE" &>/dev/null; then
  ok "ServingRuntime '$SERVING_RUNTIME' present"
else
  die "ServingRuntime '$SERVING_RUNTIME' not found after apply"
fi

for entry in "${IMAGES[@]}"; do
  ISTAG="${entry##*|}"
  if oc get istag "$ISTAG" -n "$NAMESPACE" &>/dev/null; then
    ok "Imagestream tag '$ISTAG' present"
  else
    warn "Imagestream tag '$ISTAG' not present (its first deployment will cold-pull from quay.io)"
    DEGRADED=1
  fi
done

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ "$DEGRADED" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}Setup complete — the environment is ready for the exercise.${NC}"
else
  echo -e "${YELLOW}${BOLD}Setup finished with warnings.${NC}"
  echo -e "${CYAN}The namespace and vLLM runtime are ready; one or both image pre-caches${NC}"
  echo -e "${CYAN}may be unavailable, so the affected deployment will cold-pull. Review above.${NC}"
fi
echo ""

#!/usr/bin/env bash
#
# setup.sh — Prepare the cluster for the ModelCar OCI exercise.
#
# Automates the instructor/setup steps that must run BEFORE students begin
# (everything above "Exercise starts here" in the exercise guide):
#
#   1. Create and label the exercise namespace
#   2. Expose the internal image registry (external default route)
#   3. Wait for the registry route to be admitted
#   4. Pre-cache the fallback ModelCar image into the internal registry
#   5. Pre-warm the GPU node's image cache with a short-lived pull pod
#   6. Create the vLLM ServingRuntime from the RHOAI template
#   7. Validate the setup
#
# This script MUTATES the cluster. Run it as cluster-admin.
# Re-running is safe (idempotent): existing resources are reused, not duplicated.
#
# The fallback image pre-cache (steps 4-5) is best-effort: if it fails or is
# slow, setup continues and reports a warning — the essential registry and
# ServingRuntime are still provisioned.
#
# Usage:
#   bash setup.sh
#
# Environment overrides (raise these on slow lab environments):
#   OC_REQUEST_TIMEOUT   Per-call oc request cap        (default 30s)
#   ROUTE_TIMEOUT        Wait for registry route (s)    (default 180)
#   ISTAG_TIMEOUT        Wait for fallback import (s)    (default 300)
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
NAMESPACE="prepare-modelcar"
RHOAI_NS="redhat-ods-applications"
RUNTIME_TEMPLATE="vllm-cuda-runtime-template"
SERVING_RUNTIME="vllm-cuda-runtime"

# Fallback (pre-imported) ModelCar image used when a student cannot build one.
FALLBACK_SRC="quay.io/redhattraining/modelcar-qwen3-06b:v1"
FALLBACK_ISTAG="fallback-modelcar-qwen3-06b:v1"
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"
FALLBACK_INTERNAL_IMAGE="${INTERNAL_REGISTRY}/${NAMESPACE}/${FALLBACK_ISTAG}"

# Timeouts (seconds) — override via env for slow lab environments.
ROUTE_TIMEOUT="${ROUTE_TIMEOUT:-180}"
ISTAG_TIMEOUT="${ISTAG_TIMEOUT:-300}"
PREWARM_TIMEOUT="${PREWARM_TIMEOUT:-600}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

DEGRADED=0  # tracks non-fatal (best-effort) issues for the final summary

# Retries for critical one-shot API calls. The aggregated openshift-apiserver
# (templates, routes, imagestreams) can briefly go unavailable during a rollout;
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

echo ""
echo -e "${BOLD}ModelCar OCI Exercise — Setup${NC}"
echo "Preparing namespace, registry, fallback image, and vLLM runtime"

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
header "2. Expose Internal Image Registry"
###############################################################################

retry_cmd "$RETRY_ATTEMPTS" "$RETRY_DELAY" \
  oc patch configs.imageregistry.operator.openshift.io/cluster \
    --type merge \
    -p '{"spec":{"defaultRoute":true}}' >/dev/null \
  || die "Failed to patch image registry config"
ok "Requested external default route on the internal registry"

###############################################################################
header "3. Wait for Registry Route"
###############################################################################

# Poll the route's real readiness (Admitted condition), not just the presence of
# a host — a route object can appear before it is actually served, which is the
# false positive the naive "does the host exist" check suffers from.
info "Waiting for the registry route to be admitted (up to ${ROUTE_TIMEOUT}s)..."
REGISTRY=""
ADMITTED=""
for _ in $(seq 1 "$(attempts_for "$ROUTE_TIMEOUT")"); do
  REGISTRY=$(oc get route default-route -n openshift-image-registry \
    -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  ADMITTED=$(oc get route default-route -n openshift-image-registry \
    -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null || echo "")
  [[ -n "$REGISTRY" && "$ADMITTED" == "True" ]] && break
  sleep "$POLL_INTERVAL"
done

if [[ -n "$REGISTRY" && "$ADMITTED" == "True" ]]; then
  ok "Registry route admitted: $REGISTRY"
else
  die "Registry route not admitted within ${ROUTE_TIMEOUT}s (host='${REGISTRY:-none}', admitted='${ADMITTED:-none}').
     Check: oc get route default-route -n openshift-image-registry
     Tip:   re-run with a larger timeout, e.g. ROUTE_TIMEOUT=360 bash setup.sh"
fi

###############################################################################
header "4. Pre-cache Fallback ModelCar Image (best-effort)"
###############################################################################

FALLBACK_READY=false

# Import the external fallback image into the internal registry as a local-ref
# imagestream tag, so students without Podman can still deploy.
if oc tag --source=docker "$FALLBACK_SRC" \
     "${NAMESPACE}/${FALLBACK_ISTAG}" \
     --reference-policy=local >/dev/null 2>&1; then
  ok "Tagged $FALLBACK_SRC -> ${NAMESPACE}/${FALLBACK_ISTAG}"

  # The tag triggers an async import; wait until it resolves to a real image
  # before pre-warming (otherwise the pull pod would fail).
  info "Waiting for the fallback image to import (up to ${ISTAG_TIMEOUT}s)..."
  IMPORTED=""
  for _ in $(seq 1 "$(attempts_for "$ISTAG_TIMEOUT")"); do
    IMPORTED=$(oc get istag "$FALLBACK_ISTAG" -n "$NAMESPACE" \
      -o jsonpath='{.image.metadata.name}' 2>/dev/null || echo "")
    [[ -n "$IMPORTED" ]] && break
    sleep "$POLL_INTERVAL"
  done

  if [[ -n "$IMPORTED" ]]; then
    # The manifest is now resolved into the imagestream. The layer blobs are
    # pulled and cached by the pre-warm pod in the next step.
    ok "Fallback image manifest imported (layers cached by the pre-warm step)"
    FALLBACK_READY=true
  else
    warn "Fallback image did not import within ${ISTAG_TIMEOUT}s"
    echo -e "     ${CYAN}Why:${NC} the cluster may not be able to pull from quay.io"
    echo -e "     ${CYAN}Check:${NC} oc describe istag ${FALLBACK_ISTAG} -n ${NAMESPACE}"
    DEGRADED=1
  fi
else
  warn "Failed to tag the fallback image (skipping fallback pre-cache)"
  DEGRADED=1
fi

###############################################################################
header "5. Pre-warm GPU Node Image Cache (best-effort)"
###############################################################################

if [[ "$FALLBACK_READY" == "true" ]]; then
  # A short-lived pod pulls the fallback image so it is cached on the node,
  # making the fallback deployment start quickly. Recreate it cleanly each run.
  oc delete pod prewarm -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1

  if cat <<EOF | oc apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: prewarm
  namespace: ${NAMESPACE}
spec:
  containers:
  - name: pull
    image: ${FALLBACK_INTERNAL_IMAGE}
    command: ["true"]
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
EOF
  then
    ok "Created pre-warm pod"
    info "Waiting for it to pull the image and complete (up to ${PREWARM_TIMEOUT}s)..."
    if wait_pod_complete prewarm "$NAMESPACE" "$PREWARM_TIMEOUT"; then
      ok "Pre-warm pod completed — fallback image is cached on the node"
    else
      PHASE=$(oc get pod prewarm -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
      REASON=$(oc get pod prewarm -n "$NAMESPACE" \
        -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
      warn "Pre-warm pod did not complete (phase='${PHASE}'${REASON:+, reason='${REASON}'})"
      echo -e "     ${CYAN}Check:${NC} oc describe pod prewarm -n ${NAMESPACE}"
      DEGRADED=1
    fi
    # Always remove the pre-warm pod, on success or failure, so setup never
    # leaves a dangling pod that students would see in `oc get pods`.
    oc delete pod prewarm -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  else
    warn "Failed to create the pre-warm pod"
    DEGRADED=1
  fi
else
  warn "Skipping node pre-warm — fallback image is not available"
  DEGRADED=1
fi

###############################################################################
header "6. Create vLLM ServingRuntime"
###############################################################################

# Retry the lookup: the openshift-apiserver that serves templates can be briefly
# unavailable (e.g. mid-rollout), which would otherwise be misread as "missing".
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
header "7. Validate Setup"
###############################################################################

if oc get servingruntime "$SERVING_RUNTIME" -n "$NAMESPACE" &>/dev/null; then
  ok "ServingRuntime '$SERVING_RUNTIME' present"
else
  die "ServingRuntime '$SERVING_RUNTIME' not found after apply"
fi

if oc get istag "$FALLBACK_ISTAG" -n "$NAMESPACE" &>/dev/null; then
  ok "Fallback imagestream tag '$FALLBACK_ISTAG' present"
else
  warn "Fallback imagestream tag '$FALLBACK_ISTAG' not present (students must build their own image)"
  DEGRADED=1
fi

ok "Registry route: $REGISTRY"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ "$DEGRADED" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}Setup complete — the environment is ready for the exercise.${NC}"
else
  echo -e "${YELLOW}${BOLD}Setup finished with warnings.${NC}"
  echo -e "${CYAN}The registry and vLLM runtime are ready; the optional fallback image path${NC}"
  echo -e "${CYAN}may be unavailable. Review the warnings above.${NC}"
fi
echo ""

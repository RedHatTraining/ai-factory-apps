#!/usr/bin/env bash
#
# clean.sh — Reset the cluster to a known-good state for the ModelCar exercise.
#
# This is the "get out of jail" card: run it any time the environment is in a
# bad or unknown state and you want to start over. It reverses everything
# setup.sh does (and, as a side effect of deleting the exercise namespace,
# also removes the resources students create during the lab), so that
# check-env.sh passes cleanly afterwards.
#
# What it reverses:
#   1. The exercise namespace 'prepare-modelcar' and everything in it
#      (ServingRuntime, fallback imagestream, pre-warm pod, and the student's
#       InferenceService, its route, and the modelcar imagestream)
#   2. The ModelCar image cached on the GPU node, so the next run's first deploy
#      is a genuine cold pull (best-effort, via `oc debug node` + crictl)
#   3. The internal image registry external route (spec.defaultRoute -> false)
#   4. Local Podman images/login left on the student machine (best-effort)
#
# What it deliberately does NOT touch:
#   - The image registry managementState (stays Managed — required by check-env)
#   - RHOAI, KServe, GPU operator, or any other platform component
#
# Idempotent: safe to run repeatedly, whether or not setup.sh ever ran.
# This script MUTATES the cluster. Run it as cluster-admin.
#
# Usage:
#   bash clean.sh
#
# Environment overrides (raise on slow lab environments):
#   OC_REQUEST_TIMEOUT   Per-call oc request cap        (default 30s)
#   NS_DELETE_TIMEOUT    Wait for namespace deletion (s)(default 180)
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
# `oc wait` is exempt: it runs a long watch bounded by its own --timeout.
OC_REQUEST_TIMEOUT="${OC_REQUEST_TIMEOUT:-30s}"
oc() {
  if [[ "${1:-}" == "wait" ]]; then
    command oc "$@"
  else
    command oc --request-timeout="$OC_REQUEST_TIMEOUT" "$@"
  fi
}

# retry_cmd <attempts> <delay> <cmd...> — run cmd until it succeeds or attempts
# run out. Guards against transient apiserver blips (a false "not found" here
# would skip a delete and leave leftovers that fail check-env.sh).
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

# --- Exercise constants -------------------------------------------------------
NAMESPACE="prepare-modelcar"
STUDENT_IMAGESTREAM="modelcar-qwen3-06b"   # built/pushed by students
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"
NODE_IMAGE_REPO="${INTERNAL_REGISTRY}/${NAMESPACE}/${STUDENT_IMAGESTREAM}"
REGISTRY_CONFIG="configs.imageregistry.operator.openshift.io/cluster"
NS_DELETE_TIMEOUT="${NS_DELETE_TIMEOUT:-180}"

WARNINGS=0

echo ""
echo -e "${BOLD}ModelCar OCI Exercise — Clean / Reset${NC}"
echo "Reversing setup.sh and removing exercise artifacts"

# --- Preconditions ------------------------------------------------------------
if ! oc whoami &>/dev/null; then
  die "Not logged in to the cluster. Run: oc login -u <admin> -p <password> <api-url>"
fi
if ! oc auth can-i '*' '*' --all-namespaces &>/dev/null; then
  die "Current user ($(command oc whoami 2>/dev/null)) is not cluster-admin. Log in as a cluster-admin user."
fi
ok "Logged in as $(oc whoami) with cluster-admin privileges"

# Capture the external registry host BEFORE we remove the route, so the local
# Podman cleanup below can find images tagged with it.
REGISTRY=$(oc get route default-route -n openshift-image-registry \
  -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

###############################################################################
header "1. Delete Exercise Namespace"
###############################################################################

if retry_cmd 3 3 oc get namespace "$NAMESPACE" &>/dev/null; then
  # Request deletion without blocking, then wait explicitly so we can report a
  # clear message if finalizers (e.g. on the InferenceService) slow it down.
  oc delete namespace "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1

  info "Waiting for '$NAMESPACE' to terminate (up to ${NS_DELETE_TIMEOUT}s)..."
  if oc wait --for=delete "namespace/$NAMESPACE" --timeout="${NS_DELETE_TIMEOUT}s" >/dev/null 2>&1; then
    ok "Namespace '$NAMESPACE' deleted"
  else
    warn "Namespace '$NAMESPACE' is still terminating after ${NS_DELETE_TIMEOUT}s"
    echo -e "     ${CYAN}Why:${NC} a resource in the namespace may have a stuck finalizer"
    echo -e "     ${CYAN}Check:${NC} oc get namespace $NAMESPACE -o jsonpath='{.status}'"
    echo -e "     ${CYAN}Check:${NC} oc get inferenceservice -n $NAMESPACE -o yaml   (look for metadata.finalizers)"
    ((WARNINGS++))
  fi
else
  info "Namespace '$NAMESPACE' not present — nothing to delete"
fi

###############################################################################
header "2. Evict ModelCar Image from the GPU Node Cache (best-effort)"
###############################################################################

# After the first deploy, the GPU node caches the ModelCar image. Removing it
# from the node's CRI store makes the NEXT run's first deploy a genuine cold
# pull, which is what the cold-vs-warm timing step demonstrates. This touches
# only the node's local image cache — not the internal registry and not the
# locally built Podman image.
#
# Implemented with `oc debug node` + crictl (requires cluster-admin). Best-effort:
# any failure here is a warning and never blocks the reset. Targets only the
# student repo (an exact repo match, so the fallback image is left alone).
GPU_NODES=$(oc get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.capacity.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
  | awk '$2 ~ /^[0-9]+$/ && $2 > 0 {print $1}')

if [[ -z "$GPU_NODES" ]]; then
  info "No GPU nodes found — skipping node cache eviction"
else
  # Remote script (runs on the node): find the image IDs whose repository column
  # matches the student repo EXACTLY, then remove them. The exact match excludes
  # the fallback repo, and `sort -u` collapses the shared v1/v2 ID to one rmi.
  # (An exact awk match is used because `crictl images -q <repo>` does not match
  # a fully-qualified internal-registry reference.)
  REMOTE_EVICT="imgs=\$(crictl images 2>/dev/null | awk '\$1==\"${NODE_IMAGE_REPO}\"{print \$3}' | sort -u); \
if [ -n \"\$imgs\" ]; then crictl rmi \$imgs >/dev/null 2>&1 && echo EVICTED; fi"

  for node in $GPU_NODES; do
    OUT=$(command oc debug node/"$node" --quiet -- \
            chroot /host /bin/bash -c "$REMOTE_EVICT" 2>/dev/null)
    if [[ "$OUT" == *EVICTED* ]]; then
      ok "Evicted ModelCar image from node '$node' cache"
    else
      info "No ModelCar image cached on node '$node' (or already evicted)"
    fi
  done
fi

###############################################################################
header "3. Un-expose Internal Image Registry"
###############################################################################

# Reverse setup.sh's defaultRoute:true. We do NOT touch managementState, which
# must remain Managed for check-env.sh (and the registry itself) to be happy.
CURRENT_ROUTE=$(oc get "$REGISTRY_CONFIG" -o jsonpath='{.spec.defaultRoute}' 2>/dev/null || echo "")
if [[ "$CURRENT_ROUTE" == "true" ]]; then
  if oc patch "$REGISTRY_CONFIG" --type merge \
       -p '{"spec":{"defaultRoute":false}}' >/dev/null 2>&1; then
    ok "Reverted registry defaultRoute to false (the operator will remove the route)"
  else
    warn "Failed to revert registry defaultRoute"
    ((WARNINGS++))
  fi
else
  info "Registry defaultRoute is not enabled — nothing to revert"
fi

###############################################################################
header "4. Local Podman Artifacts (student machine, best-effort)"
###############################################################################

# Remove only the final tagged images. We deliberately do NOT prune the build
# cache (no `podman system/builder prune`), so the builder-stage layer that
# downloads the ~1.2GB model from Hugging Face is reused on the next build —
# a rebuild after clean.sh does not re-download the model.
#
# Extension point: add more student-side cleanup here as the lab grows.
if type -P podman &>/dev/null; then
  REMOVED=0
  if [[ -n "$REGISTRY" ]]; then
    for tag in v1 v2; do
      IMG="${REGISTRY}/${NAMESPACE}/${STUDENT_IMAGESTREAM}:${tag}"
      if podman image exists "$IMG" 2>/dev/null; then
        podman rmi "$IMG" >/dev/null 2>&1 && { info "Removed local image ${IMG}"; REMOVED=1; }
      fi
    done
    podman logout "$REGISTRY" >/dev/null 2>&1 || true
  else
    info "Registry route already gone — cannot match local image tags (skipping)"
  fi
  [[ "$REMOVED" -eq 0 ]] && info "No local exercise images to remove"
else
  info "podman not found — skipping local image cleanup"
fi

###############################################################################
# Summary
###############################################################################

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ "$WARNINGS" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}Cleanup complete — the environment is back to a known-good state.${NC}"
else
  echo -e "${YELLOW}${BOLD}Cleanup finished with ${WARNINGS} warning(s) — review the messages above.${NC}"
fi
echo -e "${CYAN}Verify with:${NC} bash check-env.sh"
echo ""

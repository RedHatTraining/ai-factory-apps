#!/usr/bin/env bash
#
# clean.sh — Reset the cluster to a known-good state for the Quantize exercise.
#
# This is the "get out of jail" card: run it any time the environment is in a
# bad or unknown state and you want to start over. It reverses everything
# setup.sh does (and, as a side effect of deleting the exercise namespace,
# also removes the resources students create during the lab), so that
# check-env.sh passes cleanly afterwards.
#
# What it reverses:
#   1. The exercise namespace 'prepare-quantize' and everything in it
#      (InferenceServices, Jobs, PVCs, ServingRuntime, and any other
#       resources students created during the exercise)
#
# What it deliberately does NOT touch:
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
NAMESPACE="prepare-quantize"
NS_DELETE_TIMEOUT="${NS_DELETE_TIMEOUT:-180}"

WARNINGS=0

echo ""
echo -e "${BOLD}Quantize Exercise — Clean / Reset${NC}"
echo "Reversing setup.sh and removing exercise artifacts"

# --- Preconditions ------------------------------------------------------------
if ! oc whoami &>/dev/null; then
  die "Not logged in to the cluster. Run: oc login -u <admin> -p <password> <api-url>"
fi
if ! oc auth can-i '*' '*' --all-namespaces &>/dev/null; then
  die "Current user ($(command oc whoami 2>/dev/null)) is not cluster-admin. Log in as a cluster-admin user."
fi
ok "Logged in as $(oc whoami) with cluster-admin privileges"

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
# Summary
###############################################################################

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ "$WARNINGS" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}Cleanup complete — the environment is back to a known-good state.${NC}"
else
  echo -e "${YELLOW}${BOLD}Cleanup finished with ${WARNINGS} warning(s) — review the messages above.${NC}"
fi
echo ""

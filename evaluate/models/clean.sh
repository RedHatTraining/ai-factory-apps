#!/usr/bin/env bash
#
# clean.sh — Remove all resources created by setup.sh for the model evaluation exercise.
#
# This script deletes the exercise namespace and everything inside it:
#   - InferenceService(s) and their pods
#   - ServingRuntime
#   - ImageStream tags and pre-warm pods
#   - The namespace itself
#
# Re-running is safe: missing resources are silently skipped.
#
# Usage:
#   bash clean.sh
#
# After cleanup, verify with:
#   oc get namespace evaluate-models
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

NAMESPACE="evaluate-models"
NS_DELETE_TIMEOUT="${NS_DELETE_TIMEOUT:-120s}"
WARNINGS=0

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

echo ""
echo -e "${BOLD}Evaluate Models Exercise — Clean / Reset${NC}"
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
header "1. Check Namespace"
###############################################################################

if ! oc get namespace "$NAMESPACE" &>/dev/null; then
  info "Namespace '$NAMESPACE' does not exist — nothing to clean"
  echo ""
  echo -e "${GREEN}${BOLD}Cleanup complete — the environment is back to a known-good state.${NC}"
  echo ""
  exit 0
fi
ok "Namespace '$NAMESPACE' exists — proceeding with cleanup"

###############################################################################
header "2. Delete InferenceServices"
###############################################################################

if oc get inferenceservice -n "$NAMESPACE" &>/dev/null 2>&1; then
  oc delete inferenceservice --all -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  ok "Deleted InferenceServices"

  info "Waiting for model pods to terminate..."
  oc wait --for=delete pod -l serving.kserve.io/inferenceservice \
    -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
  ok "Model pods terminated"
else
  info "No InferenceServices found"
fi

###############################################################################
header "3. Revert GPU Hardware Profile"
###############################################################################

RHOAI_NS="redhat-ods-applications"
HP_NAME="gpu-profile"
HP_MEM_DEFAULT_ORIG="8Gi"
HP_MEM_MAX_ORIG="12Gi"

if oc get hardwareprofile "$HP_NAME" -n "$RHOAI_NS" &>/dev/null; then
  if retry_cmd 3 5 \
    oc patch hardwareprofile "$HP_NAME" -n "$RHOAI_NS" --type='json' -p="[
      {\"op\": \"replace\", \"path\": \"/spec/identifiers/1/defaultCount\", \"value\": \"${HP_MEM_DEFAULT_ORIG}\"},
      {\"op\": \"replace\", \"path\": \"/spec/identifiers/1/maxCount\", \"value\": \"${HP_MEM_MAX_ORIG}\"}
    ]" >/dev/null 2>&1; then
    ok "Reverted '$HP_NAME' memory: default=${HP_MEM_DEFAULT_ORIG}, max=${HP_MEM_MAX_ORIG}"
  else
    warn "Failed to revert '$HP_NAME' memory settings"
    WARNINGS=$(( WARNINGS + 1 ))
  fi
else
  info "HardwareProfile '$HP_NAME' not found — skipping revert"
fi

###############################################################################
header "4. Delete Namespace"
###############################################################################

info "Deleting namespace '$NAMESPACE'..."
oc delete namespace "$NAMESPACE" --wait=false --ignore-not-found >/dev/null 2>&1

info "Waiting for namespace to be removed (up to ${NS_DELETE_TIMEOUT})..."
if oc wait --for=delete namespace/"$NAMESPACE" --timeout="$NS_DELETE_TIMEOUT" 2>/dev/null; then
  ok "Namespace '$NAMESPACE' removed"
else
  warn "Namespace '$NAMESPACE' still terminating after ${NS_DELETE_TIMEOUT}"
  echo -e "     ${CYAN}Check:${NC} oc get namespace ${NAMESPACE} -o jsonpath='{.status.phase}'"
  WARNINGS=$(( WARNINGS + 1 ))
fi

###############################################################################
header "5. Verify"
###############################################################################

if oc get namespace "$NAMESPACE" &>/dev/null; then
  warn "Namespace '$NAMESPACE' still exists (may be in Terminating state)"
  WARNINGS=$(( WARNINGS + 1 ))
else
  ok "Namespace '$NAMESPACE' is gone"
fi

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ "$WARNINGS" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}Cleanup complete — the environment is back to a known-good state.${NC}"
else
  echo -e "${YELLOW}${BOLD}Cleanup finished with ${WARNINGS} warning(s). Review messages above.${NC}"
  echo -e "${CYAN}Verify:${NC} oc get namespace ${NAMESPACE}"
fi
echo ""

#!/usr/bin/env bash
#
# intro-reset.sh — Reset the cluster to pre-lab state for the intro exercise.
#
# This script removes only resources created during the intro GE exercise:
#   - Simulator stack (Helm release llm-d-sim in llm-d-lab namespace)
#   - llm-d-lab namespace
#   - DSC patch (restores rawDeploymentServiceConfig and removes WVA)
#   - RHOAI additional operators (Helm release rhoai-operators: Service Mesh 3,
#     KEDA, User Workload Monitoring)
#
# This script does NOT touch:
#   - Operators installed by agnosticv (NFD, Serverless, Authorino, Pipelines,
#     RHOAI, NVIDIA GPU)
#   - The DataScienceCluster or DataScienceClusterInitialization
#   - Pre-existing platform resources (cert-manager, keycloak, etc.)
#
# After running this script, students can start fresh from the beginning
# of the intro GE exercise.
#
# Idempotent — safe to run at any point.
#
# Usage:
#   bash scripts/intro-reset.sh
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
step()  { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}"; }

###############################################################################
# PRE-FLIGHT
###############################################################################

step "Pre-flight checks"

if ! command -v oc &>/dev/null; then
  fail "oc CLI is not installed."
  exit 1
fi
ok "oc CLI found"

if ! oc whoami --request-timeout=10s &>/dev/null; then
  fail "Not logged in or cluster unreachable. Run 'oc login' first."
  exit 1
fi
ok "Logged in as $(oc whoami)"

if ! oc get nodes --request-timeout=10s &>/dev/null; then
  fail "Cannot reach cluster API. Check your connection and try again."
  exit 1
fi
ok "Cluster API reachable"

###############################################################################
# 1 — Helm uninstall llm-d-sim
###############################################################################

step "1. Remove simulator stack"

if helm status llm-d-sim -n llm-d-lab &>/dev/null 2>&1; then
  helm uninstall llm-d-sim -n llm-d-lab --timeout=60s 2>/dev/null \
    && ok "Uninstalled llm-d-sim Helm release" \
    || warn "llm-d-sim uninstall had issues — namespace deletion will clean up"
else
  ok "llm-d-sim Helm release not found"
fi

###############################################################################
# 2 — Delete llm-d-lab namespace
###############################################################################

step "2. Delete llm-d-lab namespace"

if oc get ns llm-d-lab &>/dev/null; then
  oc project default 2>/dev/null || true
  oc delete ns llm-d-lab --timeout=120s 2>/dev/null \
    && ok "Deleted llm-d-lab namespace" \
    || warn "llm-d-lab deletion timed out — may still be terminating"
else
  oc project default 2>/dev/null || true
  ok "llm-d-lab namespace already deleted"
fi

###############################################################################
# 3 — Revert DSC patch (remove WVA, restore rawDeploymentServiceConfig)
###############################################################################

step "3. Revert DSC patch"

if oc get dsc default-dsc &>/dev/null 2>&1; then
  oc patch datasciencecluster default-dsc --type=merge \
    -p '{"spec":{"components":{"kserve":{"rawDeploymentServiceConfig":"Headless","wva":{"managementState":"Removed"}}}}}' \
    2>/dev/null \
    && ok "Reverted DSC (WVA Removed, rawDeploymentServiceConfig Headless)" \
    || warn "DSC patch failed — check manually"
else
  ok "DataScienceCluster not found — nothing to revert"
fi

###############################################################################
# 4 — Helm uninstall rhoai-operators
###############################################################################

step "4. Remove additional operators (Service Mesh 3, KEDA, monitoring)"

if helm status rhoai-operators -n default &>/dev/null 2>&1; then
  # Delete KEDA CRs before uninstalling the operator
  if oc get ns openshift-keda &>/dev/null 2>&1; then
    oc delete kedacontroller --all -n openshift-keda \
      --ignore-not-found --timeout=30s 2>/dev/null || true
    ok "Deleted KedaController CRs"
  fi

  info "Uninstalling rhoai-operators Helm release..."
  helm uninstall rhoai-operators -n default --timeout=120s 2>/dev/null \
    && ok "Uninstalled rhoai-operators" \
    || warn "rhoai-operators uninstall had issues"
else
  ok "rhoai-operators Helm release not found"
fi

###############################################################################
# 5 — Clean up stale KEDA resources
###############################################################################

step "5. Clean up stale KEDA resources"

# KedaController with stuck finalizers
if oc get ns openshift-keda &>/dev/null 2>&1; then
  KEDA_CONTROLLERS=$(oc get kedacontroller -n openshift-keda --no-headers -o name 2>/dev/null || true)
  if [[ -n "$KEDA_CONTROLLERS" ]]; then
    for kc in $KEDA_CONTROLLERS; do
      if ! oc delete "$kc" -n openshift-keda --timeout=10s 2>/dev/null; then
        warn "KedaController deletion timed out — patching finalizer"
        oc patch "$kc" -n openshift-keda --type=json \
          -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
      fi
    done
    ok "Deleted KedaController"
  else
    ok "No KedaController found"
  fi
else
  ok "openshift-keda namespace not found"
fi

# Stale KEDA APIService
STALE_API=$(oc get apiservice v1beta1.external.metrics.k8s.io \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)

if [[ "$STALE_API" == "False" ]]; then
  oc delete apiservice v1beta1.external.metrics.k8s.io 2>/dev/null \
    && ok "Deleted stale external.metrics APIService" \
    || warn "Could not delete stale APIService"
elif [[ -n "$STALE_API" ]]; then
  ok "external.metrics APIService is healthy — leaving in place"
else
  ok "external.metrics APIService not found"
fi

# Wait for openshift-keda namespace to terminate
if oc get ns openshift-keda &>/dev/null 2>&1; then
  info "Waiting for openshift-keda namespace to terminate..."
  oc wait --for=delete namespace/openshift-keda --timeout=60s 2>/dev/null \
    && ok "openshift-keda namespace deleted" \
    || warn "openshift-keda still terminating"
fi

###############################################################################
# 6 — Summary
###############################################################################

step "Done"
echo ""

LINGERING=()
for ns in llm-d-lab openshift-keda; do
  if oc get ns "$ns" &>/dev/null 2>&1; then
    LINGERING+=("$ns")
  fi
done

if [[ ${#LINGERING[@]} -gt 0 ]]; then
  warn "Some namespaces still present:"
  for ns in "${LINGERING[@]}"; do
    PHASE=$(oc get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
    echo -e "       $ns ($PHASE)"
  done
  echo ""
  echo -e "${YELLOW}Namespaces marked 'Terminating' will finish on their own.${NC}"
  echo ""
else
  ok "All lab namespaces removed"
fi

echo -e "${GREEN}Intro reset complete.${NC}"
echo -e "You can now start fresh from the intro exercise."
echo ""

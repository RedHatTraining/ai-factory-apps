#!/usr/bin/env bash
#
# cluster-reset.sh — Reset the cluster to pre-lab state.
#
# This script removes resources created during the intro GE exercise:
#   - Simulator stack (Helm release llm-d-sim in llm-d-lab namespace)
#   - llm-d-lab namespace
#   - RHOAI DataScienceCluster and DataScienceClusterInitialization
#   - RHOAI operators (Helm release rhoai-operators)
#
# After running this script, students can start fresh from the beginning
# of the intro GE exercise.
#
# Idempotent — safe to run at any point.
#
# Usage:
#   bash scripts/cluster-reset.sh
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
# 3 — Delete RHOAI CRs (while operators still run to process finalizers)
###############################################################################

step "3. Delete RHOAI custom resources"

# DataScienceCluster (created by student via oc apply)
if oc get dsc default-dsc &>/dev/null 2>&1; then
  info "Deleting DataScienceCluster — this takes 1-2 minutes..."
  oc delete dsc default-dsc --timeout=180s 2>/dev/null \
    && ok "Deleted DataScienceCluster" \
    || warn "DataScienceCluster deletion timed out"
else
  ok "DataScienceCluster not found"
fi

# DataScienceClusterInitialization (auto-created by RHOAI operator)
if oc get dsci default-dsci &>/dev/null 2>&1; then
  oc delete dsci default-dsci --timeout=60s 2>/dev/null \
    && ok "Deleted DataScienceClusterInitialization" \
    || warn "DataScienceClusterInitialization deletion timed out"
else
  ok "DataScienceClusterInitialization not found"
fi

###############################################################################
# 4 — Helm uninstall rhoai-operators
###############################################################################

step "4. Remove RHOAI operators"

if helm status rhoai-operators -n default &>/dev/null 2>&1; then
  info "Uninstalling rhoai-operators — this removes operator subscriptions..."
  helm uninstall rhoai-operators -n default --timeout=120s 2>/dev/null \
    && ok "Uninstalled rhoai-operators Helm release" \
    || warn "rhoai-operators uninstall had issues"
else
  ok "rhoai-operators Helm release not found"
fi

###############################################################################
# 5 — Clean up auto-created operator resources
###############################################################################

step "5. Clean up auto-created operator resources"

info "Waiting for operator pods to stop..."
sleep 10

# KEDA: KedaController (auto-created by KEDA operator)
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
    ok "KedaController not found"
  fi
else
  ok "openshift-keda namespace not found"
fi

# Serverless: KnativeServing and KnativeEventing
if oc api-resources --api-group=operator.knative.dev &>/dev/null 2>&1; then
  oc delete knativeserving --all -A \
    --ignore-not-found --timeout=60s 2>/dev/null || true
  oc delete knativeeventing --all -A \
    --ignore-not-found --timeout=60s 2>/dev/null || true
  ok "Deleted Knative custom resources"
else
  ok "Knative CRDs not present"
fi

# Pipelines: TektonConfig (must be cleaned after operator is gone)
if oc api-resources --api-group=operator.tekton.dev &>/dev/null 2>&1; then
  TEKTON_TYPES=(tektonconfig tektonpipeline tektontrigger tektonchain tektonaddon tektonresult)
  FOUND_TEKTON=false

  for res in "${TEKTON_TYPES[@]}"; do
    ITEMS=$(oc get "$res" --no-headers -o name 2>/dev/null || true)
    [[ -z "$ITEMS" ]] && continue
    FOUND_TEKTON=true
    for item in $ITEMS; do
      if ! oc delete "$item" --timeout=10s 2>/dev/null; then
        oc patch "$item" --type=json \
          -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
      fi
    done
  done

  if [[ "$FOUND_TEKTON" == "true" ]]; then
    ok "Cleaned up Tekton custom resources"
  else
    ok "No Tekton custom resources found"
  fi
else
  ok "Tekton CRDs not present"
fi

# Delete stale KEDA APIService that blocks namespace deletion
if oc get apiservice v1beta1.external.metrics.k8s.io &>/dev/null 2>&1; then
  API_STATUS=$(oc get apiservice v1beta1.external.metrics.k8s.io \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)

  if [[ "$API_STATUS" == "False" ]]; then
    oc delete apiservice v1beta1.external.metrics.k8s.io 2>/dev/null \
      && ok "Deleted stale external.metrics APIService" \
      || warn "Could not delete stale APIService"
  else
    ok "external.metrics APIService is healthy — leaving in place"
  fi
else
  ok "external.metrics APIService not found"
fi

###############################################################################
# 6 — Delete operator namespaces
###############################################################################

step "6. Delete operator namespaces"

# Only delete namespaces if they are empty (no running pods)
# This prevents deleting pre-existing namespaces
OPERATOR_NS=(
  openshift-nfd
  openshift-serverless
  openshift-keda
  redhat-ods-operator
  redhat-ods-applications
  redhat-ods-monitoring
  knative-serving
  knative-eventing
  openshift-pipelines
)

for ns in "${OPERATOR_NS[@]}"; do
  if ! oc get ns "$ns" &>/dev/null 2>&1; then
    ok "$ns already deleted"
    continue
  fi

  NS_PHASE=$(oc get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

  if [[ "$NS_PHASE" == "Terminating" ]]; then
    info "$ns is Terminating — waiting..."
    oc wait --for=delete namespace/"$ns" --timeout=60s 2>/dev/null \
      && ok "Deleted $ns" \
      || warn "$ns still terminating"
    continue
  fi

  # Check if namespace has running pods
  RUNNING_PODS=$(oc get pods -n "$ns" --no-headers 2>/dev/null \
    | grep -c Running || true)

  if [[ "$RUNNING_PODS" -eq 0 ]]; then
    oc delete ns "$ns" --timeout=60s 2>/dev/null \
      && ok "Deleted $ns" \
      || warn "$ns deletion timed out"
  else
    warn "$ns has $RUNNING_PODS running pod(s) — skipping (may be pre-existing)"
  fi
done

###############################################################################
# 7 — Summary
###############################################################################

step "Done"
echo ""

LINGERING=()
ALL_NS=("${OPERATOR_NS[@]}" llm-d-lab)
for ns in "${ALL_NS[@]}"; do
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
  echo -e "${YELLOW}Namespaces marked 'Active' may be pre-existing (not course-created)."
  echo -e "Namespaces marked 'Terminating' will finish on their own.${NC}"
  echo ""
else
  ok "All lab namespaces removed"
fi

echo -e "${GREEN}Cluster reset complete.${NC}"
echo -e "You can now start fresh from the intro exercise."
echo ""

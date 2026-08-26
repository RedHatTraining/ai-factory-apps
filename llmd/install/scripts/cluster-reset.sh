#!/usr/bin/env bash
#
# cluster-reset.sh — Full course reset: removes all lab resources across modules.
#
# This script removes resources created during all course exercises:
#   - Module-specific resources (security, monitoring, autoscaling, P/D, gateway)
#   - Simulator stack (Helm release llm-d-sim)
#   - llm-d-lab namespace
#   - DSC patch (restores rawDeploymentServiceConfig and removes WVA)
#   - Additional operators (Helm release rhoai-operators: Service Mesh 3,
#     KEDA, User Workload Monitoring)
#
# This script does NOT touch:
#   - Operators installed by agnosticv (NFD, Serverless, Authorino, Pipelines,
#     RHOAI, NVIDIA GPU)
#   - The DataScienceCluster or DataScienceClusterInitialization (agnosticv-owned)
#   - Pre-existing platform resources (cert-manager, keycloak, etc.)
#   - openshift-operators, openshift-monitoring (platform namespaces)
#
# Idempotent — safe to run at any point in the course.
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
# 1 — Remove security resources (Kuadrant, TLS, Auth)
###############################################################################

step "1. Remove security resources"

if oc get ns llm-d-lab &>/dev/null; then
  oc delete authpolicy llm-d-lab-auth-policy -n llm-d-lab \
    --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete tlspolicy llm-d-lab-tls-policy -n llm-d-lab \
    --ignore-not-found --timeout=30s 2>/dev/null || true
  ok "Auth/TLS policies removed"
else
  ok "llm-d-lab namespace not found — skipping"
fi

if oc api-resources --api-group=cert-manager.io &>/dev/null 2>&1; then
  oc delete clusterissuer selfsigned \
    --ignore-not-found --timeout=30s 2>/dev/null || true
  ok "ClusterIssuer cleaned"
fi

if oc get ns kuadrant-system &>/dev/null; then
  oc delete kuadrant kuadrant -n kuadrant-system \
    --ignore-not-found --timeout=60s 2>/dev/null || true
  ok "Kuadrant CR removed"

  for sub in $(oc get sub -n kuadrant-system --no-headers -o name 2>/dev/null || true); do
    oc delete "$sub" -n kuadrant-system --ignore-not-found 2>/dev/null || true
  done
  for csv in $(oc get csv -n kuadrant-system --no-headers -o name 2>/dev/null \
    | grep -E 'authorino|dns-operator|limitador' || true); do
    oc delete "$csv" -n kuadrant-system --ignore-not-found 2>/dev/null || true
  done
  ok "Kuadrant subscriptions cleaned"
fi

###############################################################################
# 2 — Remove monitoring resources
###############################################################################

step "2. Remove monitoring resources"

if oc get ns llm-d-lab &>/dev/null; then
  oc delete prometheusrule llm-d-inference-alerts vllm-metrics-alias -n llm-d-lab \
    --ignore-not-found 2>/dev/null || true
  oc delete pod curl-helper -n llm-d-lab \
    --ignore-not-found --force --grace-period=0 2>/dev/null || true
  ok "Monitoring resources removed"
fi

rm -rf must-gather.local.* must-gather-llm-d.tar.gz 2>/dev/null || true
ok "Local must-gather artifacts cleaned"

###############################################################################
# 3 — Remove autoscaling resources
###############################################################################

step "3. Remove autoscaling resources"

if oc get ns llm-d-lab &>/dev/null; then
  oc delete va llm-d-sim-va -n llm-d-lab --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete scaledobject llm-d-sim-keda -n llm-d-lab --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete hpa --all -n llm-d-lab --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete inferenceobjective critical standard batch -n llm-d-lab --ignore-not-found 2>/dev/null || true
  ok "Autoscaling resources removed"
fi

oc delete clustertriggerauthentication ai-inference-keda-thanos --ignore-not-found 2>/dev/null || true
oc delete clusterrolebinding keda-metrics-reader-monitoring --ignore-not-found 2>/dev/null || true

if oc get ns openshift-keda &>/dev/null; then
  oc delete secret keda-metrics-reader-token -n openshift-keda --ignore-not-found 2>/dev/null || true
  oc delete sa keda-metrics-reader -n openshift-keda --ignore-not-found 2>/dev/null || true
fi
ok "KEDA auth chain removed"

###############################################################################
# 4 — Remove P/D resources and node labels
###############################################################################

step "4. Remove P/D resources and node labels"

if oc get ns llm-d-lab &>/dev/null; then
  oc delete deployment llm-d-sim-prefill llm-d-sim-decode -n llm-d-lab \
    --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete service llm-d-sim-prefill llm-d-sim-decode -n llm-d-lab \
    --ignore-not-found 2>/dev/null || true
  ok "P/D deployments and services removed"
fi

LABELED_NODES=$(oc get nodes -l llm-d.ai/role -o name 2>/dev/null || true)
if [[ -n "$LABELED_NODES" ]]; then
  for node in $LABELED_NODES; do
    oc label "$node" llm-d.ai/role- 2>/dev/null || true
  done
  ok "Node labels removed"
else
  ok "No llm-d.ai/role labels found"
fi

###############################################################################
# 5 — Remove gateway and routing resources
###############################################################################

step "5. Remove gateway and routing resources"

if oc get ns llm-d-lab &>/dev/null; then
  oc delete route llm-d-lab-gateway -n llm-d-lab --ignore-not-found 2>/dev/null || true
  oc delete httproute llm-d-sim-route -n llm-d-lab --ignore-not-found 2>/dev/null || true
  oc delete envoyfilter llm-d-sim-extproc llm-d-original-dst -n llm-d-lab --ignore-not-found 2>/dev/null || true
  oc delete destinationrule llm-d-sim-epp -n llm-d-lab --ignore-not-found 2>/dev/null || true
  oc delete gateway llm-d-lab-gateway -n llm-d-lab --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete configmap llm-d-lab-gateway-config -n llm-d-lab --ignore-not-found 2>/dev/null || true
  ok "Gateway and routing resources removed"
else
  ok "llm-d-lab namespace not found — skipping"
fi

###############################################################################
# 6 — Helm uninstall llm-d-sim
###############################################################################

step "6. Helm uninstall llm-d-sim"

if helm status llm-d-sim -n llm-d-lab &>/dev/null 2>&1; then
  helm uninstall llm-d-sim -n llm-d-lab --timeout=60s 2>/dev/null \
    && ok "Uninstalled llm-d-sim" \
    || warn "llm-d-sim uninstall had issues — namespace deletion will clean up"
else
  ok "llm-d-sim release not found"
fi

###############################################################################
# 7 — Delete llm-d-lab namespace
###############################################################################

step "7. Delete llm-d-lab namespace"

if oc get ns llm-d-lab &>/dev/null; then
  oc project default 2>/dev/null || true
  oc delete ns llm-d-lab --timeout=120s 2>/dev/null \
    && ok "Deleted llm-d-lab" \
    || warn "llm-d-lab deletion timed out — may still be terminating"
else
  oc project default 2>/dev/null || true
  ok "llm-d-lab already gone"
fi

###############################################################################
# 8 — Revert DSC patch
###############################################################################

step "8. Revert DSC patch"

if oc get dsc default-dsc &>/dev/null 2>&1; then
  oc patch datasciencecluster default-dsc --type=merge \
    -p '{"spec":{"components":{"kserve":{"rawDeploymentServiceConfig":"Headless","wva":{"managementState":"Removed"}}}}}' \
    2>/dev/null \
    && ok "Reverted DSC (WVA Removed, rawDeploymentServiceConfig Headless)" \
    || warn "DSC patch failed — check manually"
else
  ok "DataScienceCluster not found"
fi

###############################################################################
# 9 — Helm uninstall rhoai-operators (Service Mesh 3, KEDA, monitoring)
###############################################################################

step "9. Remove additional operators"

# Delete KEDA CRs before uninstalling the operator
if oc get ns openshift-keda &>/dev/null 2>&1; then
  oc delete kedacontroller --all -n openshift-keda \
    --ignore-not-found --timeout=30s 2>/dev/null || true
fi

if helm status rhoai-operators -n default &>/dev/null 2>&1; then
  info "Uninstalling rhoai-operators..."
  helm uninstall rhoai-operators -n default --timeout=120s 2>/dev/null \
    && ok "Uninstalled rhoai-operators" \
    || warn "rhoai-operators uninstall had issues"
else
  ok "rhoai-operators release not found"
fi

###############################################################################
# 10 — Clean up stale KEDA resources
###############################################################################

step "10. Clean up stale resources"

# Stuck KedaController finalizers
if oc get ns openshift-keda &>/dev/null 2>&1; then
  for kc in $(oc get kedacontroller -n openshift-keda --no-headers -o name 2>/dev/null || true); do
    warn "Found stuck $kc — patching finalizer"
    oc patch "$kc" -n openshift-keda --type=json \
      -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
  done
fi

# Stale KEDA APIService
STALE_API=$(oc get apiservice v1beta1.external.metrics.k8s.io \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)

if [[ "$STALE_API" == "False" ]]; then
  oc delete apiservice v1beta1.external.metrics.k8s.io 2>/dev/null \
    && ok "Deleted stale external.metrics APIService" \
    || warn "Could not delete stale APIService"
else
  ok "No stale APIServices"
fi

# Delete kuadrant-system namespace (course-created)
if oc get ns kuadrant-system &>/dev/null; then
  oc delete ns kuadrant-system --timeout=60s 2>/dev/null \
    && ok "Deleted kuadrant-system" \
    || warn "kuadrant-system deletion timed out"
fi

# Wait for openshift-keda namespace if still terminating
if oc get ns openshift-keda &>/dev/null 2>&1; then
  info "Waiting for openshift-keda namespace to terminate..."
  oc wait --for=delete namespace/openshift-keda --timeout=60s 2>/dev/null \
    && ok "openshift-keda namespace deleted" \
    || warn "openshift-keda still terminating"
fi

###############################################################################
# 11 — Summary
###############################################################################

step "Done"
echo ""

LINGERING=()
for ns in llm-d-lab openshift-keda kuadrant-system; do
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
  ok "All course namespaces removed"
fi

echo -e "${GREEN}Cluster reset complete.${NC}"
echo -e "You can now start fresh from the intro exercise."
echo ""

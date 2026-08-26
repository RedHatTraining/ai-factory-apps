#!/usr/bin/env bash
#
# cluster-reset.sh — Reset the cluster to pre-lab state (before Phase 0.2).
#
# After running this script, students can start fresh from Phase 0.2
# (installing the RHOAI operator stack via Helm).
#
# What this script removes:
#   - AuthPolicy, TLSPolicy, ClusterIssuer, Kuadrant CR
#   - PrometheusRule alerts, curl-helper pod, local must-gather artifacts
#   - VariantAutoscaling, ScaledObject, InferenceObjectives, KEDA auth
#   - Prefill/Decode deployments, node labels (llm-d.ai/role)
#   - ORIGINAL_DST EnvoyFilter
#   - Gateway, ext_proc EnvoyFilter, DestinationRule, HTTPRoute, Route
#     * Phase 0.3: Helm release llm-d-sim (simulator, EPP, InferencePool, monitors)
#     * Phase 0.2: DataScienceCluster, DSCInitialization, Helm release rhoai-operators
#
# What this script does NOT touch:
#   - Pre-existing operators (subscriptions/namespaces the Helm chart skipped
#     via lookup() guards are left in place — they were there before the course)
#   - Pre-existing platform resources (cert-manager, ODF, keycloak, etc.)
#   - CSVs, CRDs, or InstallPlans (OLM handles those)
#   - openshift-operators, openshift-monitoring (platform namespaces)
#
# ORDERING: CRs with finalizers (NIM Account, DSC, DSCI, KedaController, Kuadrant, etc.)
# are deleted WHILE their operators still run so operators process finalizers.
# Operator subscriptions are removed AFTER all CRs are gone (via helm uninstall).
# Any orphaned CRs left by Helm removing their operator are cleaned up last.
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
# 1 — Remove security resources
###############################################################################

step "1. Remove security resources"

if oc get ns llm-d-lab &>/dev/null; then
  oc delete authpolicy llm-d-lab-auth-policy -n llm-d-lab \
    --ignore-not-found --timeout=30s 2>/dev/null \
    && ok "Deleted AuthPolicy" \
    || ok "AuthPolicy not found"

  oc delete tlspolicy llm-d-lab-tls-policy -n llm-d-lab \
    --ignore-not-found --timeout=30s 2>/dev/null \
    && ok "Deleted TLSPolicy" \
    || ok "TLSPolicy not found"
else
  ok "llm-d-lab namespace not found — skipping"
fi

if oc api-resources --api-group=cert-manager.io &>/dev/null 2>&1; then
  oc delete clusterissuer selfsigned \
    --ignore-not-found --timeout=30s 2>/dev/null \
    && ok "Deleted ClusterIssuer selfsigned" \
    || ok "ClusterIssuer selfsigned not found"
else
  ok "cert-manager CRDs not present — skipping ClusterIssuer"
fi

if oc get ns kuadrant-system &>/dev/null; then
  oc delete kuadrant kuadrant -n kuadrant-system \
    --ignore-not-found --timeout=60s 2>/dev/null \
    && ok "Deleted Kuadrant CR" \
    || ok "Kuadrant CR not found"
else
  ok "kuadrant-system namespace not found — skipping"
fi

###############################################################################
# 2 — Remove Monitoring resources (monitoring alerts)
###############################################################################

step "2. Remove Monitoring resources"

if oc get ns llm-d-lab &>/dev/null; then
  oc delete prometheusrule llm-d-inference-alerts -n llm-d-lab \
    --ignore-not-found 2>/dev/null || true
  ok "Module 5 PrometheusRule removed"

  oc delete pod curl-helper -n llm-d-lab \
    --ignore-not-found --force --grace-period=0 2>/dev/null || true
  ok "Helper pod removed"
fi

rm -rf must-gather.local.* must-gather-llm-d.tar.gz 2>/dev/null || true
ok "Local must-gather artifacts cleaned"

###############################################################################
# 3 — Remove autoscaling resources (autoscaling, priority, KEDA auth)
###############################################################################

step "3. Remove autoscaling resources"

if oc get ns llm-d-lab &>/dev/null; then
  oc delete va llm-d-sim-va -n llm-d-lab \
    --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete scaledobject llm-d-sim-keda -n llm-d-lab \
    --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete hpa --all -n llm-d-lab \
    --ignore-not-found --timeout=30s 2>/dev/null || true
  ok "Autoscaling resources removed"

  oc delete inferenceobjective critical standard batch -n llm-d-lab \
    --ignore-not-found 2>/dev/null || true
  ok "InferenceObjectives removed"

  oc delete prometheusrule vllm-metrics-alias -n llm-d-lab \
    --ignore-not-found 2>/dev/null || true
  ok "Metrics alias PrometheusRule removed"
fi

oc delete clustertriggerauthentication ai-inference-keda-thanos \
  --ignore-not-found 2>/dev/null || true
oc delete clusterrolebinding keda-metrics-reader-monitoring \
  --ignore-not-found 2>/dev/null || true

if oc get ns openshift-keda &>/dev/null; then
  oc delete secret keda-metrics-reader-token -n openshift-keda \
    --ignore-not-found 2>/dev/null || true
  oc delete sa keda-metrics-reader -n openshift-keda \
    --ignore-not-found 2>/dev/null || true
fi
ok "KEDA auth chain removed"

###############################################################################
# 4 — Remove Pre-fill and Decode resources (disaggregated P/D, node labels)
###############################################################################

step "4. Remove Module 3 resources"

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
# 5 — Remove Gateway and routing resources
###############################################################################

step "5. Remove Gateway and routing resources"

if oc get ns llm-d-lab &>/dev/null; then
  oc delete route llm-d-lab-gateway -n llm-d-lab \
    --ignore-not-found 2>/dev/null || true
  oc delete httproute llm-d-sim-route -n llm-d-lab \
    --ignore-not-found 2>/dev/null || true
  oc delete envoyfilter llm-d-sim-extproc llm-d-original-dst -n llm-d-lab \
    --ignore-not-found 2>/dev/null || true
  oc delete destinationrule llm-d-sim-epp -n llm-d-lab \
    --ignore-not-found 2>/dev/null || true
  oc delete gateway llm-d-lab-gateway -n llm-d-lab \
    --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete configmap llm-d-lab-gateway-config -n llm-d-lab \
    --ignore-not-found 2>/dev/null || true
  ok "Gateway and routing resources removed"
else
  ok "llm-d-lab namespace not found — skipping"
fi

###############################################################################
# 6 — Helm uninstall llm-d-sim (Phase 0.3)
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
# 7 — Delete llm-d-lab namespace (always course-created)
###############################################################################

step "7. Delete llm-d-lab namespace"

if oc get ns llm-d-lab &>/dev/null; then
  oc project default
  oc delete ns llm-d-lab --timeout=120s 2>/dev/null \
    && ok "Deleted llm-d-lab" \
    || warn "llm-d-lab deletion timed out — may still be terminating"
else
  oc project default
  ok "llm-d-lab already gone"
fi

###############################################################################
# 8 — Delete operator CRs with finalizers (WHILE operators still run)
#
#     These CRs were created by the course (post-install manifests or
#     auto-created by course-installed operators). Operators must be
#     running to process their own finalizers. We delete CRs first,
#     then helm uninstall removes the operators in step 9.
###############################################################################

step "8. Delete operator CRs (while operators process finalizers)"

# --- RHOAI: DataScienceCluster (course-created via oc apply) ---
if oc get dsc default-dsc &>/dev/null 2>&1; then
  info "Deleting DataScienceCluster — this takes 1-2 minutes..."
  oc delete dsc default-dsc --timeout=180s 2>/dev/null \
    && ok "Deleted DataScienceCluster" \
    || warn "DSC deletion timed out"
else
  ok "DataScienceCluster not found"
fi

# --- RHOAI: NIM Account (auto-created when NIM is enabled) ---
# Must be deleted before DSCI so the nim-cleanup-finalizer is processed
# while the operator is still running. If left behind, it blocks
# redhat-ods-applications namespace deletion indefinitely.
if oc api-resources --api-group=nim.opendatahub.io &>/dev/null 2>&1 \
   && oc api-resources --api-group=nim.opendatahub.io --no-headers 2>/dev/null | grep -q account; then
  NIM_ACCOUNTS=$(oc get accounts.nim.opendatahub.io -A --no-headers -o name 2>/dev/null || true)
  if [[ -n "$NIM_ACCOUNTS" ]]; then
    for acct in $NIM_ACCOUNTS; do
      NS=$(oc get accounts.nim.opendatahub.io -A --no-headers 2>/dev/null \
        | grep "$(basename "$acct")" | awk '{print $1}')
      if ! oc delete "$acct" -n "$NS" --timeout=30s 2>/dev/null; then
        warn "NIM Account deletion timed out — patching finalizer"
        oc patch "$acct" -n "$NS" --type=json \
          -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
      fi
    done
    ok "Deleted NIM Account(s)"
  else
    ok "No NIM Accounts found"
  fi
else
  ok "NIM CRD not present — skipping"
fi

# --- RHOAI: DSCInitialization (auto-created by RHOAI operator) ---
if oc get dsci default-dsci &>/dev/null 2>&1; then
  oc delete dsci default-dsci --timeout=60s 2>/dev/null \
    && ok "Deleted DSCInitialization" \
    || warn "DSCI deletion timed out"
else
  ok "DSCInitialization not found"
fi

# --- KEDA: KedaController (auto-created by KEDA operator) ---
if oc get ns openshift-keda &>/dev/null; then
  oc delete kedacontroller --all -n openshift-keda \
    --ignore-not-found --timeout=60s 2>/dev/null \
    && ok "Deleted KedaController" \
    || warn "KedaController deletion timed out"
else
  ok "openshift-keda not found — skipping KedaController"
fi

# --- Serverless: KnativeServing and KnativeEventing ---
if oc api-resources --api-group=operator.knative.dev &>/dev/null 2>&1 \
   && oc api-resources --api-group=operator.knative.dev --no-headers 2>/dev/null | grep -q .; then
  oc delete knativeserving --all -A \
    --ignore-not-found --timeout=60s 2>/dev/null || true
  oc delete knativeeventing --all -A \
    --ignore-not-found --timeout=60s 2>/dev/null || true
  ok "Deleted Knative CRs"
else
  ok "Knative CRDs not present — skipping"
fi

# --- Kuadrant: auto-created subscriptions in kuadrant-system ---
# These are created by the rhcl-operator, not by Helm.
if oc get ns kuadrant-system &>/dev/null; then
  for sub in $(oc get sub -n kuadrant-system --no-headers -o name 2>/dev/null || true); do
    oc delete "$sub" -n kuadrant-system --ignore-not-found 2>/dev/null || true
  done
  for csv in $(oc get csv -n kuadrant-system --no-headers -o name 2>/dev/null \
    | grep -E 'authorino|dns-operator|limitador' || true); do
    oc delete "$csv" -n kuadrant-system --ignore-not-found 2>/dev/null || true
  done
  ok "Kuadrant auto-created subscriptions removed"
else
  ok "kuadrant-system not found — skipping"
fi

###############################################################################
# 9 — Helm uninstall rhoai-operators (Phase 0.2)
#
#     This removes only Helm-tracked resources: subscriptions, namespaces,
#     and operator groups that the chart created. Resources that were
#     pre-existing (guarded by lookup()) are left in place.
###############################################################################

step "9. Helm uninstall rhoai-operators"

if helm status rhoai-operators -n default &>/dev/null 2>&1; then
  info "Uninstalling rhoai-operators — this removes Helm-tracked resources only..."
  helm uninstall rhoai-operators -n default --timeout=120s 2>/dev/null \
    && ok "Uninstalled rhoai-operators" \
    || warn "rhoai-operators uninstall had issues"
else
  ok "rhoai-operators release not found"
fi

###############################################################################
# 10 — Clean up orphaned operator CRs and stale APIServices
#
#      Helm uninstall (step 9) may have removed operator subscriptions,
#      leaving behind operator CRs with stuck finalizers. These CRs were
#      auto-created by the operators — they're now orphaned with no
#      controller to process their finalizers.
#
#      Pipelines is special: its operator re-creates TektonConfig if
#      deleted while running, so we handle it AFTER the operator is gone.
###############################################################################

step "10. Clean up orphaned CRs and stale APIServices"

info "Waiting for operator pods to stop..."
sleep 10

# --- Pipelines: Tekton CRs (must be cleaned up after operator is gone) ---
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
  ok "Tekton CRs cleaned up"
else
  ok "No orphaned Tekton CRs found"
fi

# --- Check for any other operator CRs with stuck finalizers ---
STUCK_FOUND=false
for res in kedacontroller knativeserving knativeeventing accounts.nim.opendatahub.io; do
  for item in $(oc get "$res" -A --no-headers -o name 2>/dev/null || true); do
    STUCK_FOUND=true
    warn "Found stuck $item — patching finalizer"
    oc patch "$item" --type=json \
      -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
  done
done

if [[ "$STUCK_FOUND" == "false" ]]; then
  ok "No stuck operator CRs found"
fi

# --- Stale KEDA APIService ---
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

###############################################################################
# 11 — Delete orphaned namespaces
#
#      Some namespaces were auto-created by operators that Helm just
#      removed. These are now empty and orphaned. Only delete namespaces
#      that are either Terminating or have no running pods (orphaned).
#      Never delete namespaces that might be pre-existing and still in use.
###############################################################################

step "11. Delete orphaned namespaces"

# Namespaces that are always course-created (never pre-existing):
ALWAYS_COURSE_NS=(kuadrant-system)

for ns in "${ALWAYS_COURSE_NS[@]}"; do
  if oc get ns "$ns" &>/dev/null; then
    oc delete ns "$ns" --timeout=60s 2>/dev/null \
      && ok "Deleted $ns" \
      || warn "$ns deletion timed out"
  else
    ok "$ns already gone"
  fi
done

# Namespaces that MIGHT be pre-existing (operator-managed).
# Only delete if they are Terminating or empty (orphaned by our operator removal).
MAYBE_COURSE_NS=(
  openshift-nfd
  openshift-serverless
  openshift-keda
  redhat-ods-operator
  redhat-ods-applications
  redhat-ods-monitoring
  rhoai-model-registries
  rhods-notebooks
  workload-variant-autoscaler-system
  knative-serving
  knative-eventing
  knative-serving-ingress
  openshift-pipelines
)

for ns in "${MAYBE_COURSE_NS[@]}"; do
  if ! oc get ns "$ns" &>/dev/null 2>&1; then
    ok "$ns already gone"
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

  # Check if the namespace has any running pods (sign it's still active/pre-existing)
  RUNNING_PODS=$(oc get pods -n "$ns" --no-headers 2>/dev/null \
    | grep -c Running || true)

  if [[ "$RUNNING_PODS" -eq 0 ]]; then
    oc delete ns "$ns" --timeout=60s 2>/dev/null \
      && ok "Deleted orphaned $ns" \
      || warn "$ns deletion timed out"
  else
    warn "$ns has $RUNNING_PODS running pod(s) — skipping (may be pre-existing)"
  fi
done

###############################################################################
# 12 — Summary
###############################################################################

step "Done"
echo ""

LINGERING=()
ALL_NS=(kuadrant-system "${MAYBE_COURSE_NS[@]}" llm-d-lab)
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
  echo -e "Namespaces marked 'Terminating' will finish on their own. Check with:${NC}"
  echo -e "  oc get ns | grep -E 'Terminating'"
  echo ""
else
  ok "All course namespaces removed"
fi

echo -e "${GREEN}Cluster reset complete.${NC}"
echo -e "Students can now start from Phase 0.2:"
echo -e "  helm install rhoai-operators helm-charts/rhoai-3.4/"
echo ""

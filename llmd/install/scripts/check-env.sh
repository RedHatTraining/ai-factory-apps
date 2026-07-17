#!/usr/bin/env bash
#
# check-env.sh — Verify that the cluster is ready for the llm-d course.
#
# Pre-install checks (--pre-install):
#   1. Cluster access (logged in as cluster-admin)
#   2. Cluster readiness (nodes and operators available — detects fresh startup)
#   3. OpenShift version (4.20+)
#   4. Node configuration (at least 2 dedicated workers, each >=4 vCPU / 16 GiB)
#   5. Required CLI tools (oc, helm, curl, git)
#   6. cert-manager Operator installed and Succeeded
#   7. No leftover lab resources from a previous run
#   8. Cluster health (no degraded operators, authentication available)
#
# Post-install checks (--post-install):
#   9. RHOAI installed (DataScienceCluster ready, RHOAI CSV Succeeded)
#  10. GAIE CRDs present (InferencePool, InferenceObjective)
#  11. Gateway API CRDs present (gateways, httproutes, grpcroutes, referencegrants)
#  12. GatewayClass data-science-gateway-class exists
#  13. Service Mesh 3 running (istiod pod, Istio CR)
#  14. Simulator image accessible (ghcr.io reachable)
#  15. RHOAI controllers running (kserve, llmisvc, WVA)
#  16. User Workload Monitoring enabled
#  17. RHOAI llm-d container images (kserve-parameters ConfigMap has EPP, proxy, tokenizer, sidecar)
#
# Sim-stack checks (--sim-stack):
#  18. Lab namespace exists
#  19. Simulator Deployment (exists, replicas ready)
#  20. Simulator pods healthy (containers ready, not crashlooping)
#  21. EPP Deployment (exists, ready)
#  22. EPP pod healthy (all containers ready)
#  23. InferencePool exists and references EPP
#  24. Services exist with endpoints (simulator + EPP)
#  25. Simulator responds (/v1/models returns model)
#
# Usage:
#   bash scripts/check-env.sh               # all checks (pre + post + sim-stack)
#   bash scripts/check-env.sh --pre-install  # pre-install checks only (1-8)
#   bash scripts/check-env.sh --post-install # post-install checks only (9-17)
#   bash scripts/check-env.sh --sim-stack    # sim-stack checks only (18-25)
#
# If any check fails, the script tells you exactly what to do.
# Works on both macOS and Linux.
#

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()     { echo -e "  ${GREEN}✓${NC} $*"; }
fail()   { echo -e "  ${RED}✗${NC} $*"; }
warn()   { echo -e "  ${YELLOW}!${NC} $*"; }
info()   { echo -e "  ${CYAN}→${NC} $*"; }
header() { echo -e "\n${BOLD}$*${NC}"; }

PASS=0
FAIL=0
WARN=0

check_pass() { ok "$1"; ((PASS++)); }
check_fail() { fail "$1"; ((FAIL++)); }
check_warn() { warn "$1"; ((WARN++)); }

MIN_OCP_VERSION="4.20"
MIN_WORKERS=2
MIN_CPU=4
MIN_MEM_GIB=14
LAB_NAMESPACE="llm-d-lab"
HELM_RELEASE_PREFIX="llm-d"
SIM_IMAGE="quay.io/rsriniva/llm-d-sim:v0.9.2-dataset"

# Parse arguments
MODE="all"
case "${1:-}" in
  --pre-install)  MODE="pre" ;;
  --post-install) MODE="post" ;;
  --sim-stack)    MODE="sim" ;;
  --help|-h)
    echo "Usage: bash scripts/check-env.sh [--pre-install|--post-install|--sim-stack]"
    echo ""
    echo "  (no flag)       Run all checks (pre-install + post-install + sim-stack)"
    echo "  --pre-install   Run only pre-install checks (1-8)"
    echo "  --post-install  Run only post-install checks (9-17)"
    echo "  --sim-stack     Run only sim-stack checks (18-25)"
    echo ""
    echo "  Run flags in order: --pre-install → --post-install → --sim-stack"
    exit 0 ;;
esac

###############################################################################
# PRE-INSTALL CHECKS (1-8)
###############################################################################

if [[ "$MODE" != "post" && "$MODE" != "sim" ]]; then

###############################################################################
header "1. Cluster Access"
###############################################################################

if ! oc whoami &>/dev/null; then
  check_fail "Not logged in to the cluster"
  echo -e "     ${CYAN}Fix:${NC} oc login -u <admin-user> -p <password> <api-url>"
  echo ""
  echo -e "${RED}Cannot continue without cluster access. Fix the login and re-run.${NC}"
  exit 1
fi

CURRENT_USER=$(oc whoami 2>/dev/null)
check_pass "Logged in as $CURRENT_USER"

if oc auth can-i '*' '*' --all-namespaces &>/dev/null; then
  check_pass "User has cluster-admin privileges"
else
  check_fail "User $CURRENT_USER does not have cluster-admin privileges"
  echo -e "     ${CYAN}Fix:${NC} Log in as a cluster admin user"
fi

###############################################################################
header "2. Cluster Readiness"
###############################################################################

NODE_CHECK=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
CO_CHECK=$(oc get co --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [[ "$NODE_CHECK" -eq 0 || "$CO_CHECK" -eq 0 ]]; then
  check_warn "Cluster API is reachable but nodes/operators are not yet available"
  echo -e "     ${CYAN}Info:${NC} This typically happens within the first 2-5 minutes after starting a cluster."
  echo -e "     ${CYAN}Fix:${NC} Wait a few minutes, then re-run:  ${BOLD}bash scripts/check-env.sh${NC}"
  echo ""
  echo -e "${YELLOW}Continuing checks — some may fail until the cluster finishes initializing.${NC}"
  echo ""
else
  check_pass "Cluster nodes and operators are available"
fi

###############################################################################
header "3. OpenShift Version"
###############################################################################

OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
K8S_VERSION=$(oc version -o json 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('serverVersion',{}).get('gitVersion','unknown'))" 2>/dev/null \
  || echo "unknown")

check_pass "OpenShift $OCP_VERSION (Kubernetes $K8S_VERSION)"

MAJOR_MINOR=$(echo "$OCP_VERSION" | cut -d. -f1,2)
if python3 -c "exit(0 if tuple(map(int,'$MAJOR_MINOR'.split('.'))) >= tuple(map(int,'$MIN_OCP_VERSION'.split('.'))) else 1)" 2>/dev/null; then
  check_pass "Version $MAJOR_MINOR meets minimum requirement ($MIN_OCP_VERSION+)"
else
  check_fail "Version $MAJOR_MINOR is below minimum requirement ($MIN_OCP_VERSION+)"
  echo -e "     ${CYAN}Fix:${NC} This course requires OpenShift $MIN_OCP_VERSION or later"
fi

###############################################################################
header "4. Node Configuration"
###############################################################################

TOTAL_NODES=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [[ "$TOTAL_NODES" -eq 0 ]]; then
  check_fail "No nodes found — the cluster may still be starting up"
  echo -e "     ${CYAN}Fix:${NC} Wait 2-3 minutes for the cluster to fully initialize, then re-run this script"
  echo -e "     ${CYAN}Check:${NC} oc get nodes"
else
  check_pass "$TOTAL_NODES total nodes in cluster"
fi

WORKER_LIST=$(oc get nodes --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
  | while read -r node; do
    ROLES=$(oc get node "$node" -o jsonpath='{.metadata.labels}' 2>/dev/null \
      | python3 -c "import json,sys; labels=json.load(sys.stdin); roles=[k.split('/')[1] for k in labels if k.startswith('node-role.kubernetes.io/')]; print(' '.join(roles))" 2>/dev/null)
    if echo "$ROLES" | grep -q "worker" && ! echo "$ROLES" | grep -qE "control-plane|master"; then
      echo "$node"
    fi
  done)

WORKER_COUNT=$(echo "$WORKER_LIST" | grep -c . 2>/dev/null) || WORKER_COUNT=0

if [[ "$WORKER_COUNT" -ge "$MIN_WORKERS" ]]; then
  check_pass "$WORKER_COUNT dedicated worker nodes found (need $MIN_WORKERS)"
else
  check_fail "Found $WORKER_COUNT dedicated worker node(s) — need at least $MIN_WORKERS"
  echo -e "     ${CYAN}Fix:${NC} Provision a cluster with at least $MIN_WORKERS dedicated worker nodes"
  echo -e "     ${CYAN}Why:${NC} Module 3 requires separate nodes for prefill/decode disaggregation"
fi

WORKER_IDX=0
while IFS= read -r node; do
  [[ -z "$node" ]] && continue
  ((WORKER_IDX++))
  CPU=$(oc get node "$node" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null || echo "0")
  MEM_KI=$(oc get node "$node" -o jsonpath='{.status.capacity.memory}' 2>/dev/null || echo "0Ki")
  MEM_GIB=$(echo "$MEM_KI" | sed 's/Ki//' | awk '{printf "%.0f", $1/1048576}')

  if [[ "$CPU" -ge "$MIN_CPU" && "$MEM_GIB" -ge "$MIN_MEM_GIB" ]]; then
    check_pass "Worker $WORKER_IDX ($node): ${CPU} vCPUs, ${MEM_GIB} GiB RAM"
  else
    check_fail "Worker $WORKER_IDX ($node): ${CPU} vCPUs, ${MEM_GIB} GiB RAM (need ≥${MIN_CPU} vCPUs, ≥${MIN_MEM_GIB} GiB)"
  fi
done <<< "$WORKER_LIST"

###############################################################################
header "5. Required CLI Tools"
###############################################################################

get_tool_version() {
  case "$1" in
    oc)   oc version --client 2>/dev/null | head -1 ;;
    helm) helm version --short 2>/dev/null ;;
    curl) curl --version 2>/dev/null | head -1 ;;
    git)  git --version 2>/dev/null ;;
  esac
}

for tool in oc helm curl git; do
  if command -v "$tool" &>/dev/null; then
    VERSION=$(get_tool_version "$tool")
    check_pass "$tool: $VERSION"
  else
    check_fail "$tool not found in PATH"
    echo -e "     ${CYAN}Fix:${NC} Install $tool and ensure it is in your PATH"
  fi
done

###############################################################################
header "6. cert-manager Operator"
###############################################################################

CERTMGR=$(oc get csv -A --no-headers 2>/dev/null | awk '$2 ~ /^cert-manager-operator/ && /Succeeded/' | head -1)
if [[ -n "$CERTMGR" ]]; then
  CERTMGR_NAME=$(echo "$CERTMGR" | awk '{print $2}')
  check_pass "cert-manager installed: $CERTMGR_NAME"
else
  check_fail "cert-manager Operator not found or not in Succeeded phase"
  echo -e "     ${CYAN}Fix:${NC} Install the cert-manager Operator for Red Hat OpenShift from OperatorHub"
fi

###############################################################################
header "7. No Leftover Lab Resources"
###############################################################################

LEFTOVERS=0

if oc get ns "$LAB_NAMESPACE" &>/dev/null; then
  fail "Lab namespace '$LAB_NAMESPACE' still exists"
  ((LEFTOVERS++))
fi

HELM_RELEASES=$(helm list -A --short 2>/dev/null | grep "^${HELM_RELEASE_PREFIX}" || true)
if [[ -n "$HELM_RELEASES" ]]; then
  while IFS= read -r rel; do
    fail "Helm release '$rel' still exists"
    ((LEFTOVERS++))
  done <<< "$HELM_RELEASES"
fi

LLM_D_LABELED=$(oc get nodes -l llm-d.ai/role --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$LLM_D_LABELED" -gt 0 ]]; then
  fail "llm-d.ai/role labels found on $LLM_D_LABELED node(s)"
  ((LEFTOVERS++))
fi

if oc get ns "$LAB_NAMESPACE" &>/dev/null 2>&1; then
  IP_COUNT=$(oc get inferencepools -n "$LAB_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$IP_COUNT" -gt 0 ]]; then
    fail "$IP_COUNT InferencePool(s) in $LAB_NAMESPACE"
    ((LEFTOVERS++))
  fi
fi

if [[ "$LEFTOVERS" -eq 0 ]]; then
  check_pass "No leftover lab resources found"
else
  FAIL=$((FAIL + LEFTOVERS))
  echo ""
  echo -e "     ${CYAN}Fix:${NC} Run the cleanup script to remove all leftover resources:"
  echo -e "     ${BOLD}bash scripts/cluster-reset.sh${NC}"
fi

###############################################################################
header "8. Cluster Health"
###############################################################################

AUTH_AVAIL=$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
AUTH_DEGRADED=$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "Unknown")

if [[ "$AUTH_AVAIL" == "True" && "$AUTH_DEGRADED" != "True" ]]; then
  check_pass "Authentication operator: Available"
else
  check_fail "Authentication operator: Available=$AUTH_AVAIL, Degraded=$AUTH_DEGRADED"
  echo -e "     ${CYAN}Fix:${NC} Check 'oc get co authentication -o yaml' for details"
fi

DEGRADED_OPS=$(oc get co -o json 2>/dev/null | python3 -c "
import json,sys
data=json.load(sys.stdin)
degraded=[]
for item in data.get('items',[]):
    name=item['metadata']['name']
    for c in item.get('status',{}).get('conditions',[]):
        if c.get('type')=='Degraded' and c.get('status')=='True':
            degraded.append(name)
print(','.join(degraded) if degraded else '')
" 2>/dev/null || echo "")

if [[ -z "$DEGRADED_OPS" ]]; then
  check_pass "No degraded cluster operators"
else
  DEGRADED_COUNT=$(echo "$DEGRADED_OPS" | tr ',' '\n' | wc -l | tr -d ' ')
  check_warn "$DEGRADED_COUNT cluster operator(s) degraded: $DEGRADED_OPS"
  echo -e "     ${CYAN}Check:${NC} oc get co | grep -v 'True.*False.*False'"
fi

fi # end pre-install checks

###############################################################################
# POST-INSTALL CHECKS (9-17)
###############################################################################

if [[ "$MODE" != "pre" && "$MODE" != "sim" ]]; then

###############################################################################
header "9. RHOAI Installed"
###############################################################################

RHOAI_CSV=$(oc get csv -A --no-headers 2>/dev/null | awk '$2 ~ /^rhods-operator/ && /Succeeded/' | head -1)
if [[ -n "$RHOAI_CSV" ]]; then
  RHOAI_CSV_NAME=$(echo "$RHOAI_CSV" | awk '{print $2}')
  check_pass "RHOAI operator: $RHOAI_CSV_NAME"
else
  check_fail "RHOAI operator CSV not found or not in Succeeded phase"
  echo -e "     ${CYAN}Fix:${NC} Verify the Helm chart was installed: helm list -A | grep rhoai"
fi

DSC_NAME=$(oc get datasciencecluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$DSC_NAME" ]]; then
  DSC_PHASE=$(oc get datasciencecluster "$DSC_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  if [[ "$DSC_PHASE" == "Ready" ]]; then
    check_pass "DataScienceCluster '$DSC_NAME' is Ready"
  else
    check_warn "DataScienceCluster '$DSC_NAME' phase: $DSC_PHASE (expected Ready)"
    echo -e "     ${CYAN}Info:${NC} DSC takes 3-5 minutes to reconcile. Check: oc get datasciencecluster $DSC_NAME -o yaml"
  fi
else
  check_fail "No DataScienceCluster found"
  echo -e "     ${CYAN}Fix:${NC} oc apply -f helm-charts/rhoai-3.4/post-install/dsc.yaml"
fi

###############################################################################
header "10. GAIE CRDs"
###############################################################################

GAIE_CRDS=("inferencepools.inference.networking.k8s.io" "inferenceobjectives.inference.networking.x-k8s.io")
for crd in "${GAIE_CRDS[@]}"; do
  if oc get crd "$crd" &>/dev/null; then
    check_pass "CRD: $crd"
  else
    check_fail "CRD missing: $crd"
    echo -e "     ${CYAN}Fix:${NC} GAIE CRDs are installed by RHOAI when kserve is Managed. Check the DataScienceCluster."
  fi
done

###############################################################################
header "11. Gateway API CRDs"
###############################################################################

GW_CRDS=("gateways.gateway.networking.k8s.io" "httproutes.gateway.networking.k8s.io" "grpcroutes.gateway.networking.k8s.io" "referencegrants.gateway.networking.k8s.io")
for crd in "${GW_CRDS[@]}"; do
  if oc get crd "$crd" &>/dev/null; then
    check_pass "CRD: $crd"
  else
    check_fail "CRD missing: $crd"
    echo -e "     ${CYAN}Fix:${NC} Gateway API CRDs should be installed by Service Mesh / RHOAI."
  fi
done

###############################################################################
header "12. GatewayClass"
###############################################################################

if oc get gatewayclass data-science-gateway-class &>/dev/null; then
  check_pass "GatewayClass 'data-science-gateway-class' exists"
else
  check_fail "GatewayClass 'data-science-gateway-class' not found"
  echo -e "     ${CYAN}Fix:${NC} Created by RHOAI when kserve is Managed and Service Mesh is deployed."
  echo -e "     ${CYAN}Check:${NC} oc get gatewayclass"
fi

###############################################################################
header "13. Service Mesh 3 (Istio)"
###############################################################################

ISTIOD_PODS=$(oc get pods -A --no-headers -l app=istiod 2>/dev/null | grep Running | wc -l | tr -d ' ')
if [[ "$ISTIOD_PODS" -gt 0 ]]; then
  check_pass "istiod: $ISTIOD_PODS pod(s) running"
else
  check_warn "No istiod pods found running"
  echo -e "     ${CYAN}Info:${NC} istiod may take a few minutes to start after DSC creation."
  echo -e "     ${CYAN}Check:${NC} oc get pods -A -l app=istiod"
fi

if oc get crd istios.sailoperator.io &>/dev/null 2>&1; then
  ISTIO_CR=$(oc get istio -A --no-headers 2>/dev/null | head -1)
  if [[ -n "$ISTIO_CR" ]]; then
    ISTIO_NAME=$(echo "$ISTIO_CR" | awk '{print $2}')
    check_pass "Istio CR exists: $ISTIO_NAME"
#  else Temporaly commented. Not needed in llmd-intro GE
#    check_warn "Istio CRD exists but no Istio CR found yet"
  fi
else
  SM3_CSV=$(oc get csv -A --no-headers 2>/dev/null | grep servicemesh | grep Succeeded | head -1)
  if [[ -n "$SM3_CSV" ]]; then
    SM3_NAME=$(echo "$SM3_CSV" | awk '{print $2}')
    check_pass "Service Mesh 3 operator: $SM3_NAME"
  else
    check_fail "Service Mesh 3 operator not found"
    echo -e "     ${CYAN}Fix:${NC} Verify the Helm chart installed the servicemeshoperator3 subscription"
  fi
fi

###############################################################################
header "14. Simulator Image Accessibility"
###############################################################################

if oc run sim-pull-test --image="$SIM_IMAGE" --dry-run=client -o yaml &>/dev/null; then
  check_pass "Dry-run with simulator image succeeded"
else
  check_warn "Dry-run with simulator image failed (non-critical)"
fi

if curl -s --max-time 10 -o /dev/null -w "%{http_code}" "https://quay.io/v2/" 2>/dev/null | grep -qE "200|401"; then
  check_pass "quay.io registry is reachable"
else
  check_warn "Cannot reach quay.io — the cluster may not have internet access"
  echo -e "     ${CYAN}Fix:${NC} Ensure the cluster can pull from quay.io, or mirror the image to a local registry"
fi

###############################################################################
header "15. RHOAI Controllers"
###############################################################################

for ctrl in kserve-controller-manager llmisvc-controller-manager; do
  POD_COUNT=$(oc get pods -n redhat-ods-applications --no-headers 2>/dev/null \
    | grep "$ctrl" | grep Running | wc -l | tr -d ' ')
  if [[ "$POD_COUNT" -gt 0 ]]; then
    check_pass "$ctrl: $POD_COUNT pod(s) running"
  else
    check_fail "$ctrl: no running pods found"
    echo -e "     ${CYAN}Fix:${NC} oc get pods -n redhat-ods-applications | grep $ctrl"
  fi
done

WVA_COUNT=$(oc get pods -n redhat-ods-applications --no-headers 2>/dev/null \
  | grep "workload-variant-autoscaler" | grep Running | wc -l | tr -d ' ')
if [[ "$WVA_COUNT" -gt 0 ]]; then
  check_pass "workload-variant-autoscaler: $WVA_COUNT pod(s) running"
else
  check_warn "workload-variant-autoscaler: no running pods found"
  echo -e "     ${CYAN}Info:${NC} WVA is needed for Module 5. Verify DSC has wva managementState: Managed"
fi

###############################################################################
header "16. User Workload Monitoring"
###############################################################################

UWM_CONFIG=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
if echo "$UWM_CONFIG" | grep -q "enableUserWorkload: true"; then
  check_pass "User Workload Monitoring is enabled"
else
  check_fail "User Workload Monitoring is not enabled"
  echo -e "     ${CYAN}Fix:${NC} The Helm chart should have created the ConfigMap. Check:"
  echo -e "     oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml"
fi

UWM_PODS=$(oc get pods -n openshift-user-workload-monitoring --no-headers 2>/dev/null | grep Running | wc -l | tr -d ' ')
if [[ "$UWM_PODS" -gt 0 ]]; then
  check_pass "User workload monitoring pods: $UWM_PODS running"
else
  check_warn "No user workload monitoring pods running yet"
  echo -e "     ${CYAN}Info:${NC} Pods may take 1-2 minutes to start after enabling."
  echo -e "     ${CYAN}Check:${NC} oc get pods -n openshift-user-workload-monitoring"
fi

###############################################################################
header "17. RHOAI llm-d Container Images"
###############################################################################

KSERVE_PARAMS_EXISTS=$(oc get configmap kserve-parameters -n redhat-ods-applications -o name 2>/dev/null || echo "")
if [[ -z "$KSERVE_PARAMS_EXISTS" ]]; then
  check_fail "kserve-parameters ConfigMap not found in redhat-ods-applications"
  echo -e "     ${CYAN}Fix:${NC} This ConfigMap is created by the RHOAI operator when kserve is Managed."
  echo -e "     ${CYAN}Check:${NC} Verify the DataScienceCluster has kserve managementState: Managed"
else
  REQUIRED_KEYS=("kserve-llm-d-inference-scheduler" "kserve-router" "kserve-llm-d-uds-tokenizer" "kserve-llm-d-routing-sidecar")
  FRIENDLY_NAMES=("EPP (inference scheduler)" "Envoy proxy (kserve-router)" "UDS tokenizer" "P/D routing sidecar")
  MISSING_KEYS=0
  for i in "${!REQUIRED_KEYS[@]}"; do
    KEY="${REQUIRED_KEYS[$i]}"
    NAME="${FRIENDLY_NAMES[$i]}"
    IMAGE=$(oc get configmap kserve-parameters -n redhat-ods-applications -o jsonpath="{.data.${KEY}}" 2>/dev/null || echo "")
    if [[ -n "$IMAGE" ]]; then
      SHORT_IMAGE=$(echo "$IMAGE" | sed 's/@sha256:.*//')
      check_pass "$NAME: $SHORT_IMAGE"
    else
      check_fail "$NAME: key '$KEY' missing from kserve-parameters"
      ((MISSING_KEYS++))
    fi
  done
  if [[ "$MISSING_KEYS" -gt 0 ]]; then
    echo -e "     ${CYAN}Fix:${NC} These image keys are required for the llm-d sim-stack Helm chart."
    echo -e "     ${CYAN}Info:${NC} RHOAI 3.4+ should include them. Check your RHOAI version:"
    echo -e "     oc get csv -n redhat-ods-operator | grep rhods"
  fi
fi

fi # end post-install checks

###############################################################################
# SIM-STACK CHECKS (18-25)
###############################################################################

if [[ "$MODE" == "sim" || "$MODE" == "all" ]]; then

if [[ "$MODE" == "sim" ]]; then
  ###############################################################################
  header "Prerequisite Check"
  ###############################################################################

  DSC_PHASE=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ "$DSC_PHASE" != "Ready" ]]; then
    check_fail "DataScienceCluster is not Ready (phase: ${DSC_PHASE:-not found})"
    echo -e "     ${CYAN}Fix:${NC} Run the checks in order:"
    echo -e "     ${BOLD}bash scripts/check-env.sh --pre-install${NC}  (verify cluster basics)"
    echo -e "     ${BOLD}bash scripts/check-env.sh --post-install${NC} (verify RHOAI install)"
    echo -e "     Then retry:  ${BOLD}bash scripts/check-env.sh --sim-stack${NC}"
    echo ""
    echo -e "${RED}Cannot run sim-stack checks without a ready RHOAI platform. Fix the above first.${NC}"
    exit 1
  fi

  KSERVE_CM=$(oc get configmap kserve-parameters -n redhat-ods-applications -o name 2>/dev/null || echo "")
  if [[ -z "$KSERVE_CM" ]]; then
    check_fail "kserve-parameters ConfigMap not found in redhat-ods-applications"
    echo -e "     ${CYAN}Fix:${NC} The RHOAI operator has not fully initialized."
    echo -e "     Run ${BOLD}bash scripts/check-env.sh --post-install${NC} first."
    echo ""
    echo -e "${RED}Cannot run sim-stack checks without RHOAI fully configured.${NC}"
    exit 1
  fi

  check_pass "Prerequisites met (DSC Ready, kserve-parameters present)"
fi

###############################################################################
header "18. Lab Namespace"
###############################################################################

if oc get namespace "$LAB_NAMESPACE" &>/dev/null; then
  check_pass "Namespace $LAB_NAMESPACE exists"
else
  check_fail "Namespace $LAB_NAMESPACE not found"
  echo -e "     ${CYAN}Fix:${NC} oc new-project $LAB_NAMESPACE"
fi

###############################################################################
header "19. Simulator Deployment"
###############################################################################

SIM_DEPLOY=$(oc get deployment -n "$LAB_NAMESPACE" -l app.kubernetes.io/part-of=llm-d-sim-stack -o name 2>/dev/null | grep -v epp | head -1)
if [[ -n "$SIM_DEPLOY" ]]; then
  SIM_NAME=$(echo "$SIM_DEPLOY" | sed 's|deployment.apps/||')
  SIM_DESIRED=$(oc get "$SIM_DEPLOY" -n "$LAB_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
  SIM_READY=$(oc get "$SIM_DEPLOY" -n "$LAB_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  SIM_READY=${SIM_READY:-0}
  if [[ "$SIM_READY" -eq "$SIM_DESIRED" && "$SIM_DESIRED" -gt 0 ]]; then
    check_pass "Simulator deployment $SIM_NAME: $SIM_READY/$SIM_DESIRED replicas ready"
  else
    check_fail "Simulator deployment $SIM_NAME: $SIM_READY/$SIM_DESIRED replicas ready"
    echo -e "     ${CYAN}Check:${NC} oc get pods -n $LAB_NAMESPACE -l app=$SIM_NAME"
  fi
else
  check_fail "No simulator deployment found (expected label app.kubernetes.io/part-of=llm-d-sim-stack)"
  echo -e "     ${CYAN}Fix:${NC} helm install llm-d-sim helm-charts/llm-d-sim-stack/ -n $LAB_NAMESPACE"
fi

###############################################################################
header "20. Simulator Pods Healthy"
###############################################################################

SIM_PODS=$(oc get pods -n "$LAB_NAMESPACE" -l app.kubernetes.io/part-of=llm-d-sim-stack -o name 2>/dev/null | grep -v epp)
if [[ -n "$SIM_PODS" ]]; then
  CRASH_PODS=$(oc get pods -n "$LAB_NAMESPACE" -l app.kubernetes.io/part-of=llm-d-sim-stack --no-headers 2>/dev/null | grep -v epp | grep -c CrashLoopBackOff || true)
  if [[ "$CRASH_PODS" -gt 0 ]]; then
    check_fail "$CRASH_PODS simulator pod(s) in CrashLoopBackOff"
    echo -e "     ${CYAN}Check:${NC} oc logs -n $LAB_NAMESPACE <pod-name> -c simulator"
  else
    SIM_NOT_READY=$(oc get pods -n "$LAB_NAMESPACE" -l app.kubernetes.io/part-of=llm-d-sim-stack --no-headers 2>/dev/null | grep -v epp | grep -vc "Running" || true)
    if [[ "$SIM_NOT_READY" -gt 0 ]]; then
      check_warn "$SIM_NOT_READY simulator pod(s) not in Running state"
      echo -e "     ${CYAN}Info:${NC} The vllm-render sidecar downloads the model tokenizer on first start (30-60s)."
      echo -e "     ${CYAN}Check:${NC} oc get pods -n $LAB_NAMESPACE -l app.kubernetes.io/part-of=llm-d-sim-stack"
    else
      SIM_POD_COUNT=$(echo "$SIM_PODS" | wc -l | tr -d ' ')
      check_pass "All $SIM_POD_COUNT simulator pods Running with all containers ready"
    fi
  fi
else
  check_fail "No simulator pods found"
fi

###############################################################################
header "21. EPP Deployment"
###############################################################################

EPP_DEPLOY=$(oc get deployment -n "$LAB_NAMESPACE" -l app.kubernetes.io/part-of=llm-d-sim-stack -o name 2>/dev/null | grep epp | head -1)
if [[ -n "$EPP_DEPLOY" ]]; then
  EPP_NAME=$(echo "$EPP_DEPLOY" | sed 's|deployment.apps/||')
  EPP_READY=$(oc get "$EPP_DEPLOY" -n "$LAB_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  EPP_READY=${EPP_READY:-0}
  if [[ "$EPP_READY" -ge 1 ]]; then
    check_pass "EPP deployment $EPP_NAME: $EPP_READY replica(s) ready"
  else
    check_fail "EPP deployment $EPP_NAME: not ready"
    echo -e "     ${CYAN}Check:${NC} oc logs -n $LAB_NAMESPACE deploy/$EPP_NAME -c epp"
  fi
else
  check_fail "No EPP deployment found"
  echo -e "     ${CYAN}Fix:${NC} helm install llm-d-sim helm-charts/llm-d-sim-stack/ -n $LAB_NAMESPACE"
fi

###############################################################################
header "22. EPP Pod Healthy"
###############################################################################

EPP_POD=$(oc get pods -n "$LAB_NAMESPACE" -l app.kubernetes.io/part-of=llm-d-sim-stack --no-headers 2>/dev/null | grep epp | head -1)
if [[ -n "$EPP_POD" ]]; then
  EPP_STATUS=$(echo "$EPP_POD" | awk '{print $3}')
  EPP_CONTAINERS=$(echo "$EPP_POD" | awk '{print $2}')
  EPP_RESTARTS=$(echo "$EPP_POD" | awk '{print $4}')
  if [[ "$EPP_STATUS" == "Running" ]]; then
    check_pass "EPP pod Running ($EPP_CONTAINERS containers, $EPP_RESTARTS restarts)"
  else
    check_fail "EPP pod status: $EPP_STATUS"
    echo -e "     ${CYAN}Check:${NC} oc describe pod -n $LAB_NAMESPACE -l app.kubernetes.io/part-of=llm-d-sim-stack | grep -A5 epp"
  fi
else
  check_fail "No EPP pod found"
fi

###############################################################################
header "23. InferencePool"
###############################################################################

POOL_NAME=$(oc get inferencepool -n "$LAB_NAMESPACE" -o name 2>/dev/null | head -1)
if [[ -n "$POOL_NAME" ]]; then
  POOL_SHORT=$(echo "$POOL_NAME" | sed 's|inferencepool.inference.networking.k8s.io/||')
  EPP_REF=$(oc get "$POOL_NAME" -n "$LAB_NAMESPACE" -o jsonpath='{.spec.endpointPickerRef.name}' 2>/dev/null || echo "")
  if [[ -n "$EPP_REF" ]]; then
    check_pass "InferencePool $POOL_SHORT references EPP service: $EPP_REF"
  else
    check_warn "InferencePool $POOL_SHORT exists but has no endpointPickerRef"
  fi
else
  check_fail "No InferencePool found in $LAB_NAMESPACE"
  echo -e "     ${CYAN}Fix:${NC} The sim-stack Helm chart should create this. Check the Helm release:"
  echo -e "     helm list -n $LAB_NAMESPACE"
fi

###############################################################################
header "24. Services"
###############################################################################

SIM_SVC=$(oc get svc -n "$LAB_NAMESPACE" -l app.kubernetes.io/part-of=llm-d-sim-stack -o name 2>/dev/null | grep -v epp | head -1)
EPP_SVC=$(oc get svc -n "$LAB_NAMESPACE" -l app.kubernetes.io/part-of=llm-d-sim-stack -o name 2>/dev/null | grep epp | head -1)

if [[ -n "$SIM_SVC" ]]; then
  SIM_SVC_SHORT=$(echo "$SIM_SVC" | sed 's|service/||')
  SIM_ENDPOINTS=$(oc get endpoints "$SIM_SVC_SHORT" -n "$LAB_NAMESPACE" -o jsonpath='{.subsets[0].addresses}' 2>/dev/null || echo "")
  if [[ -n "$SIM_ENDPOINTS" && "$SIM_ENDPOINTS" != "null" ]]; then
    SIM_EP_COUNT=$(echo "$SIM_ENDPOINTS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")
    check_pass "Simulator service $SIM_SVC_SHORT has $SIM_EP_COUNT endpoint(s)"
  else
    check_warn "Simulator service $SIM_SVC_SHORT exists but has no endpoints yet"
  fi
else
  check_fail "No simulator service found"
fi

if [[ -n "$EPP_SVC" ]]; then
  EPP_SVC_SHORT=$(echo "$EPP_SVC" | sed 's|service/||')
  EPP_ENDPOINTS=$(oc get endpoints "$EPP_SVC_SHORT" -n "$LAB_NAMESPACE" -o jsonpath='{.subsets[0].addresses}' 2>/dev/null || echo "")
  if [[ -n "$EPP_ENDPOINTS" && "$EPP_ENDPOINTS" != "null" ]]; then
    check_pass "EPP service $EPP_SVC_SHORT has endpoints"
  else
    check_warn "EPP service $EPP_SVC_SHORT exists but has no endpoints yet"
  fi
else
  check_fail "No EPP service found"
fi

###############################################################################
header "25. Simulator Responds"
###############################################################################

if [[ -n "$SIM_SVC" ]]; then
  SIM_SVC_SHORT=$(echo "$SIM_SVC" | sed 's|service/||')
  MODELS_RESPONSE=$(oc run check-sim-health --rm -i --restart=Never --image=curlimages/curl -n "$LAB_NAMESPACE" -- curl -s --max-time 10 "http://${SIM_SVC_SHORT}:8000/v1/models" 2>/dev/null || echo "")
  if echo "$MODELS_RESPONSE" | grep -q '"object":"list"'; then
    MODEL_ID=$(echo "$MODELS_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//' || echo "unknown")
    check_pass "Simulator responds with model: $MODEL_ID"
  else
    check_fail "Simulator did not return a valid /v1/models response"
    echo -e "     ${CYAN}Check:${NC} oc logs -n $LAB_NAMESPACE deploy/$SIM_NAME -c simulator"
  fi
else
  check_fail "Cannot test simulator — no service found"
fi

fi # end sim-stack checks

###############################################################################
# Summary
###############################################################################

echo ""
header "Summary"

if [[ "$MODE" == "pre" ]]; then
  echo -e "${CYAN}Pre-install checks only (1-8). Run without flags after installing RHOAI for full validation.${NC}"
elif [[ "$MODE" == "post" ]]; then
  echo -e "${CYAN}Post-install checks only (9-17).${NC}"
elif [[ "$MODE" == "sim" ]]; then
  echo -e "${CYAN}Sim-stack checks only (18-25).${NC}"
fi

if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
  echo -e "${GREEN}All $PASS checks passed. Your cluster is ready for the llm-d course.${NC}"
elif [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}$PASS checks passed${NC}, ${YELLOW}$WARN warning(s)${NC}. Cluster is usable but review the warnings above."
else
  echo -e "${RED}$FAIL check(s) failed${NC}, $PASS passed, $WARN warning(s). Fix the issues above before continuing."
fi
echo ""

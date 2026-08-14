#!/usr/bin/env bash
#
# check-env.sh — Verify the cluster is ready for the vLLM plugins exercise.
#
# This is a pre-flight check for the platform prerequisites of the exercise.
# It makes NO changes to the cluster.
#
# Checks:
#   1.  Cluster access (logged in as cluster-admin)
#   2.  Cluster readiness (nodes and operators available)
#   3.  OpenShift version
#   4.  RHOAI 3.4 installed and DataScienceCluster Ready (KServe Managed)
#   5.  GPU availability (at least one nvidia.com/gpu node)
#   6.  Required CLI tools (oc, curl, git, python3)
#   7.  vLLM ServingRuntime template (created by RHOAI)
#   8.  GPU hardware profile (gpu-profile)
#   9.  Internal image registry is Managed (running)
#   10. No leftover resources from a previous run
#
# Unlike the ModelCar exercise, students CONSUME pre-built images here (no build,
# no push), so Podman is not required and the registry needs no external route.
#
# Usage:
#   bash check-env.sh
#
# Environment overrides:
#   OC_REQUEST_TIMEOUT   Per-call oc request cap (default 15s). Raise on slow labs.
#
# If any check fails, the script tells you what to do. Works on macOS and Linux
# (bash 3.2+). Uses no GNU-only tools (no `timeout`, no `date -d`).
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

# Cap every oc request so a slow or unreachable API server fails fast instead of
# hanging the script. This read-only check uses no `oc wait`, so the cap is safe
# to apply to every call. `command oc` avoids recursing into this function.
OC_REQUEST_TIMEOUT="${OC_REQUEST_TIMEOUT:-15s}"
oc() { command oc --request-timeout="$OC_REQUEST_TIMEOUT" "$@"; }

# retry_cmd <attempts> <delay> <cmd...> — run cmd until it succeeds or attempts
# run out. Used for resources served by the aggregated openshift-apiserver
# (e.g. templates), which can blip during a rollout and be misread as "missing".
# Kept short here so a genuinely absent resource still reports quickly.
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
LAB_NAMESPACE="prepare-plugins"
RHOAI_NS="redhat-ods-applications"
RUNTIME_TEMPLATE="vllm-cuda-runtime-template"
HW_PROFILE="gpu-profile"
MIN_RHOAI_VERSION="3.4"
CUSTOM_RUNTIME="vllm-custom-qwen3-runtime"
INFERENCE_SERVICE="qwen3-custom"

echo ""
echo -e "${BOLD}vLLM Plugins Exercise — Environment Check${NC}"
echo "Verifying platform prerequisites for deploying a model with a custom vLLM plugin"

###############################################################################
header "1. Cluster Access"
###############################################################################

if ! oc whoami &>/dev/null; then
  check_fail "Not logged in to the cluster"
  echo -e "     ${CYAN}Fix:${NC} oc login -u <admin-user> -p <password> <api-url>"
  echo -e "\n${RED}${BOLD}Cannot continue without cluster access.${NC}\n"
  exit 1
fi

CURRENT_USER=$(oc whoami 2>/dev/null)
check_pass "Logged in as $CURRENT_USER"

if oc auth can-i '*' '*' --all-namespaces &>/dev/null; then
  check_pass "User has cluster-admin privileges"
else
  check_fail "User $CURRENT_USER does not have cluster-admin privileges"
  echo -e "     ${CYAN}Why:${NC} The exercise setup imports images into the internal registry and pre-warms the GPU node"
  echo -e "     ${CYAN}Fix:${NC} Log in as a cluster-admin user"
fi

###############################################################################
header "2. Cluster Readiness"
###############################################################################

NODE_CHECK=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
CO_CHECK=$(oc get co --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [[ "$NODE_CHECK" -eq 0 || "$CO_CHECK" -eq 0 ]]; then
  check_warn "Cluster API is reachable but nodes/operators are not yet available"
  echo -e "     ${CYAN}Info:${NC} This is common in the first 2-5 minutes after a cluster starts."
  echo -e "     ${CYAN}Fix:${NC} Wait a few minutes, then re-run this script."
else
  check_pass "Cluster nodes ($NODE_CHECK) and operators ($CO_CHECK) are available"
fi

###############################################################################
header "3. OpenShift Version"
###############################################################################

OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
if [[ "$OCP_VERSION" != "unknown" ]]; then
  check_pass "OpenShift $OCP_VERSION"
else
  check_warn "Could not determine OpenShift version"
fi

###############################################################################
header "4. RHOAI 3.4 Installed"
###############################################################################

RHOAI_CSV=$(oc get csv -n "$RHOAI_NS" --no-headers 2>/dev/null | awk '$1 ~ /^rhods-operator/ && /Succeeded/' | head -1)
if [[ -z "$RHOAI_CSV" ]]; then
  # Fall back to a cluster-wide search (operator may report in the operator namespace)
  RHOAI_CSV=$(oc get csv -A --no-headers 2>/dev/null | awk '$2 ~ /^rhods-operator/ && /Succeeded/' | head -1)
  RHOAI_CSV_NAME=$(echo "$RHOAI_CSV" | awk '{print $2}')
else
  RHOAI_CSV_NAME=$(echo "$RHOAI_CSV" | awk '{print $1}')
fi

if [[ -n "$RHOAI_CSV_NAME" ]]; then
  check_pass "RHOAI operator: $RHOAI_CSV_NAME"
  # Strip the "rhods-operator." prefix (and optional leading "v") with pure bash.
  RHOAI_VERSION="${RHOAI_CSV_NAME#rhods-operator.}"
  RHOAI_VERSION="${RHOAI_VERSION#v}"
  RHOAI_MM=$(echo "$RHOAI_VERSION" | cut -d. -f1,2)
  if python3 -c "exit(0 if tuple(map(int,'$RHOAI_MM'.split('.'))) >= tuple(map(int,'$MIN_RHOAI_VERSION'.split('.'))) else 1)" 2>/dev/null; then
    check_pass "RHOAI version $RHOAI_MM meets minimum requirement ($MIN_RHOAI_VERSION+)"
  else
    check_fail "RHOAI version $RHOAI_MM is below minimum requirement ($MIN_RHOAI_VERSION+)"
    echo -e "     ${CYAN}Fix:${NC} This exercise requires RHOAI $MIN_RHOAI_VERSION or later"
  fi
else
  check_fail "RHOAI operator CSV not found or not in Succeeded phase"
  echo -e "     ${CYAN}Fix:${NC} Install Red Hat OpenShift AI 3.4 and wait for the operator to reach Succeeded"
fi

DSC_NAME=$(oc get datasciencecluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$DSC_NAME" ]]; then
  # Read the authoritative top-level `Ready` condition, not `.status.phase`.
  # The phase is a coarse aggregate that briefly flips to "Not Ready" whenever
  # the operator re-reconciles (e.g. right after clean.sh deletes a namespace),
  # so retry a few times to ride out a transient blip before warning.
  dsc_ready() {
    [[ "$(oc get datasciencecluster "$DSC_NAME" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]
  }
  if retry_cmd 6 5 dsc_ready; then
    check_pass "DataScienceCluster '$DSC_NAME' is Ready"
  else
    DSC_PHASE=$(oc get datasciencecluster "$DSC_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    check_warn "DataScienceCluster '$DSC_NAME' is not Ready (phase: $DSC_PHASE)"
    echo -e "     ${CYAN}Info:${NC} The DSC takes a few minutes to reconcile. Check: oc get datasciencecluster $DSC_NAME"
  fi
else
  check_fail "No DataScienceCluster found"
  echo -e "     ${CYAN}Fix:${NC} RHOAI is not fully configured — a DataScienceCluster must exist with KServe Managed"
fi

# KServe must be Managed for the InferenceService / OCI storageUri path to work.
KSERVE_STATE=$(oc get datasciencecluster "$DSC_NAME" -o jsonpath='{.spec.components.kserve.managementState}' 2>/dev/null || echo "")
if [[ "$KSERVE_STATE" == "Managed" ]]; then
  check_pass "KServe component is Managed"
elif [[ -n "$KSERVE_STATE" ]]; then
  check_fail "KServe component managementState is '$KSERVE_STATE' (expected Managed)"
  echo -e "     ${CYAN}Fix:${NC} Set spec.components.kserve.managementState: Managed in the DataScienceCluster"
else
  check_warn "Could not determine KServe managementState"
fi

###############################################################################
header "5. GPU Availability"
###############################################################################

GPU_NODES=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.capacity.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
  | awk '$2 ~ /^[0-9]+$/ && $2 > 0')
GPU_NODE_COUNT=$(echo "$GPU_NODES" | grep -c . 2>/dev/null) || GPU_NODE_COUNT=0
TOTAL_GPUS=$(echo "$GPU_NODES" | awk '{sum+=$2} END{print sum+0}')

if [[ "$GPU_NODE_COUNT" -ge 1 ]]; then
  check_pass "$GPU_NODE_COUNT GPU node(s) with $TOTAL_GPUS total nvidia.com/gpu"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    NODE=$(echo "$line" | awk '{print $1}')
    GPUS=$(echo "$line" | awk '{print $2}')
    info "$NODE: $GPUS GPU(s)"
  done <<< "$GPU_NODES"
else
  check_fail "No schedulable nvidia.com/gpu capacity found on any node"
  echo -e "     ${CYAN}Why:${NC} The InferenceService requests 1 GPU (nvidia.com/gpu: 1)"
  echo -e "     ${CYAN}Fix:${NC} Ensure a GPU worker exists and the NVIDIA GPU Operator + NFD are installed and healthy"
  echo -e "     ${CYAN}Check:${NC} oc get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.nvidia\\.com/gpu"
fi

# GPU Operator + NFD are what advertise nvidia.com/gpu — surface their state as a hint.
GPU_OP=$(oc get csv -A --no-headers 2>/dev/null | awk '$2 ~ /^gpu-operator-certified/ && /Succeeded/' | head -1)
if [[ -n "$GPU_OP" ]]; then
  info "NVIDIA GPU Operator: $(echo "$GPU_OP" | awk '{print $2}')"
elif [[ "$GPU_NODE_COUNT" -eq 0 ]]; then
  check_warn "NVIDIA GPU Operator not found in Succeeded phase"
fi

###############################################################################
header "6. Required CLI Tools"
###############################################################################

get_tool_version() {
  case "$1" in
    oc)      oc version --client 2>/dev/null | head -1 ;;
    curl)    curl --version 2>/dev/null | head -1 ;;
    git)     git --version 2>/dev/null ;;
    python3) python3 --version 2>/dev/null ;;
  esac
}

# Use `type -P` (not `command -v`) so we detect the real binary in PATH and are
# not fooled by the `oc` shell function defined above. Podman is NOT required:
# this exercise consumes pre-built images and builds nothing locally.
for tool in oc curl git python3; do
  if type -P "$tool" &>/dev/null; then
    check_pass "$tool: $(get_tool_version "$tool")"
  else
    check_fail "$tool not found in PATH"
    echo -e "     ${CYAN}Fix:${NC} Install $tool and ensure it is in your PATH"
  fi
done

###############################################################################
header "7. vLLM ServingRuntime Template"
###############################################################################

if retry_cmd 3 3 oc get template "$RUNTIME_TEMPLATE" -n "$RHOAI_NS" &>/dev/null; then
  check_pass "Template '$RUNTIME_TEMPLATE' exists in $RHOAI_NS"
else
  check_fail "Template '$RUNTIME_TEMPLATE' not found in $RHOAI_NS"
  echo -e "     ${CYAN}Why:${NC} The setup step processes this template to create the vllm-cuda-runtime ServingRuntime"
  echo -e "     ${CYAN}Fix:${NC} This template ships with RHOAI. Verify RHOAI/KServe is fully installed."
fi

###############################################################################
header "8. GPU Hardware Profile"
###############################################################################

if retry_cmd 3 3 oc get hardwareprofile "$HW_PROFILE" -n "$RHOAI_NS" &>/dev/null; then
  check_pass "Hardware profile '$HW_PROFILE' exists in $RHOAI_NS"
else
  check_fail "Hardware profile '$HW_PROFILE' not found in $RHOAI_NS"
  echo -e "     ${CYAN}Why:${NC} The InferenceService references this profile via annotations"
  echo -e "     ${CYAN}Fix:${NC} Create the gpu-profile hardware profile, or adjust the InferenceService annotations"
  echo -e "     ${CYAN}Check:${NC} oc get hardwareprofile -n $RHOAI_NS"
fi

###############################################################################
header "9. Internal Image Registry"
###############################################################################

# The registry only needs to be Managed (running): setup imports images into it
# and the GPU node pulls them internally. No external route is required, because
# students never push — they consume pre-built images.
REG_STATE=$(oc get configs.imageregistry.operator.openshift.io/cluster -o jsonpath='{.spec.managementState}' 2>/dev/null || echo "")
if [[ "$REG_STATE" == "Managed" ]]; then
  check_pass "Internal image registry is Managed"
else
  check_fail "Internal image registry managementState is '${REG_STATE:-unknown}' (expected Managed)"
  echo -e "     ${CYAN}Why:${NC} The exercise imports and serves images from the internal registry"
  echo -e "     ${CYAN}Fix:${NC} oc patch configs.imageregistry.operator.openshift.io/cluster --type merge -p '{\"spec\":{\"managementState\":\"Managed\"}}'"
fi

###############################################################################
header "10. No Leftover Resources"
###############################################################################

LEFTOVERS=0
if oc get namespace "$LAB_NAMESPACE" &>/dev/null; then
  check_warn "Namespace '$LAB_NAMESPACE' already exists (leftover from a previous run?)"
  echo -e "     ${CYAN}Fix:${NC} bash clean.sh   (or: oc delete project $LAB_NAMESPACE, then wait for full deletion)"
  ((LEFTOVERS++))

  if oc get inferenceservice "$INFERENCE_SERVICE" -n "$LAB_NAMESPACE" &>/dev/null; then
    check_warn "InferenceService '$INFERENCE_SERVICE' exists in $LAB_NAMESPACE"
    ((LEFTOVERS++))
  fi
  if oc get servingruntime "$CUSTOM_RUNTIME" -n "$LAB_NAMESPACE" &>/dev/null; then
    check_warn "ServingRuntime '$CUSTOM_RUNTIME' exists in $LAB_NAMESPACE"
    ((LEFTOVERS++))
  fi
fi

if [[ "$LEFTOVERS" -eq 0 ]]; then
  check_pass "No leftover lab resources found"
fi

###############################################################################
# Summary
###############################################################################

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
TOTAL=$((PASS + FAIL + WARN))
echo -e "${BOLD}Results:${NC} ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${WARN} warning(s)${NC} (${TOTAL} total)"

if [[ "$FAIL" -eq 0 && "$WARN" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}Environment ready for the vLLM plugins exercise.${NC}"
elif [[ "$FAIL" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}Environment ready${NC} ${YELLOW}(review the warnings above).${NC}"
else
  echo -e "${RED}${BOLD}Fix the ${FAIL} failure(s) above before starting the exercise.${NC}"
fi
echo ""

exit 0

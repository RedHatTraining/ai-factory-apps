#!/usr/bin/env bash
#
# check-pd-reqs.sh — Verify baseline cluster state before starting P/D exercise.
#
# Checks:
#   1. Cluster access
#   2. Lab namespace exists
#   3. Simulator deployment (3 replicas, Available)
#   4. EPP deployment (Available)
#   5. Gateway deployment and route
#   6. EnvoyFilters (ext_proc + ORIGINAL_DST)
#   7. InferencePool exists
#   8. EPP config is default (single-profile, not disagg)
#   9. No leftover P/D deployments from a previous run
#  10. No stale node labels (llm-d.ai/role)
#  11. Worker nodes (at least 2 dedicated workers)
#  12. Connectivity test (request through gateway returns 200)
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

NS="llm-d-lab"

echo ""
echo -e "${BOLD}Prefill/Decode exercise Prerequisite Check${NC}"
echo "Verifying Prefill/Decode exercise baseline cluster state"

########################################################################
header "1. Cluster Access"
########################################################################
if ! oc whoami &>/dev/null; then
  fail "Not logged in to OpenShift"
  echo -e "     ${CYAN}Fix:${NC} oc login <cluster-api-url> -u <admin-user>"
  echo -e "\n${RED}${BOLD}Cannot continue without cluster access.${NC}"
  exit 1
fi
check_pass "Logged in as $(oc whoami)"

########################################################################
header "2. Lab Namespace"
########################################################################
if oc get namespace "$NS" &>/dev/null; then
  check_pass "Namespace $NS exists"
else
  check_fail "Namespace $NS not found"
  echo -e "     ${CYAN}Fix:${NC} Complete the first two exercises in this lesson."
fi

########################################################################
header "3. Simulator Deployment"
########################################################################
if oc get deployment llm-d-sim -n "$NS" &>/dev/null; then
  READY=$(oc get deployment llm-d-sim -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  DESIRED=$(oc get deployment llm-d-sim -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  READY=${READY:-0}
  if [[ "$READY" -ge 3 ]]; then
    check_pass "Simulator deployment: ${READY}/${DESIRED} replicas ready"
  elif [[ "$READY" -gt 0 ]]; then
    check_warn "Simulator deployment: ${READY}/${DESIRED} replicas ready (expected 3)"
    echo -e "     ${CYAN}Fix:${NC} oc scale deployment llm-d-sim -n $NS --replicas=3"
  else
    check_fail "Simulator deployment: 0/${DESIRED} replicas ready"
    echo -e "     ${CYAN}Fix:${NC} Complete the first two exercises in this lesson."
  fi

  NOT_RUNNING=$(oc get pods -n "$NS" -l app=llm-d-sim --no-headers 2>/dev/null \
    | grep -cv 'Running' || true)
  if [[ "$NOT_RUNNING" -gt 0 ]]; then
    check_warn "${NOT_RUNNING} simulator pod(s) not in Running state"
    echo -e "     ${CYAN}Fix:${NC} Wait for pods to stabilize (vllm-render sidecar takes 60-90s)"
  fi
else
  check_fail "Simulator deployment llm-d-sim not found"
  echo -e "     ${CYAN}Fix:${NC} Complete the first two exercises in this lesson."
fi

########################################################################
header "4. EPP Deployment"
########################################################################
if oc get deployment llm-d-sim-epp -n "$NS" &>/dev/null; then
  EPP_AVAIL=$(oc get deployment llm-d-sim-epp -n "$NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
  if [[ "$EPP_AVAIL" == "True" ]]; then
    check_pass "EPP deployment Available"
  else
    check_fail "EPP deployment exists but not Available"
    echo -e "     ${CYAN}Fix:${NC} oc delete pod -n $NS -l app=llm-d-sim-epp (restart EPP)"
  fi
else
  check_fail "EPP deployment llm-d-sim-epp not found"
  echo -e "     ${CYAN}Fix:${NC} Complete the first two exercises in this lesson."
fi

########################################################################
header "5. Gateway and Route"
########################################################################
GW_COUNT=$(oc get deployment -n "$NS" -l 'gateway.networking.k8s.io/gateway-name' \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$GW_COUNT" -gt 0 ]]; then
  check_pass "Gateway deployment exists"
else
  check_fail "Gateway deployment not found"
  echo -e "     ${CYAN}Fix:${NC} Complete the first two exercises in this lesson."
fi

ROUTE_HOST=$(oc get route llm-d-lab-gateway -n "$NS" \
  -o jsonpath='{.status.ingress[0].host}' 2>/dev/null)
if [[ -n "$ROUTE_HOST" ]]; then
  check_pass "Route llm-d-lab-gateway has host: ${ROUTE_HOST}"
else
  check_fail "Route llm-d-lab-gateway not found or has no host"
  echo -e "     ${CYAN}Fix:${NC} Complete the first two exercises in this lesson."
fi

########################################################################
header "6. EnvoyFilters"
########################################################################
if oc get envoyfilter llm-d-sim-extproc -n "$NS" &>/dev/null; then
  check_pass "EnvoyFilter llm-d-sim-extproc exists"
else
  check_fail "EnvoyFilter llm-d-sim-extproc not found"
  echo -e "     ${CYAN}Fix:${NC} Complete the first two exercises in this lesson."
fi

if oc get envoyfilter llm-d-original-dst -n "$NS" &>/dev/null; then
  check_pass "EnvoyFilter llm-d-original-dst exists"
else
  check_fail "EnvoyFilter llm-d-original-dst not found"
  echo -e "     ${CYAN}Fix:${NC} Complete the first two exercises in this lesson."
fi

########################################################################
header "7. InferencePool"
########################################################################
if oc get inferencepool -n "$NS" --no-headers &>/dev/null 2>&1 \
   && [[ $(oc get inferencepool -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ') -gt 0 ]]; then
  POOL_NAME=$(oc get inferencepool -n "$NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  check_pass "InferencePool ${POOL_NAME} exists"
else
  check_fail "No InferencePool found in $NS"
  echo -e "     ${CYAN}Fix:${NC} Complete the first two exercises in this lesson."
fi

########################################################################
header "8. EPP Config (defaults)"
########################################################################
if oc get configmap llm-d-sim-plugins -n "$NS" &>/dev/null; then
  CONFIG=$(oc get configmap llm-d-sim-plugins -n "$NS" -o jsonpath='{.data.default-plugins\.yaml}' 2>/dev/null)
  if echo "$CONFIG" | grep -q 'disagg-profile-handler'; then
    check_fail "EPP config has disaggregation plugins (leftover from a previous run?)"
    echo -e "     ${CYAN}Fix:${NC} Run bash clean-pd.sh to reset"
  elif echo "$CONFIG" | grep -q 'queue-scorer'; then
    check_pass "EPP config is default (queue-scorer + kv-cache-utilization-scorer)"
  else
    check_warn "EPP config exists but has unexpected content"
    echo -e "     ${CYAN}Fix:${NC} Run bash clean-pd.sh to reset"
  fi
else
  check_fail "ConfigMap llm-d-sim-plugins not found"
  echo -e "     ${CYAN}Fix:${NC} Complete the first two exercises in this lesson."
fi

########################################################################
header "9. No Leftover P/D Deployments"
########################################################################
PD_LEFTOVER=0
if oc get deployment llm-d-sim-prefill -n "$NS" &>/dev/null; then
  check_fail "Leftover deployment llm-d-sim-prefill found"
  PD_LEFTOVER=1
fi
if oc get deployment llm-d-sim-decode -n "$NS" &>/dev/null; then
  check_fail "Leftover deployment llm-d-sim-decode found"
  PD_LEFTOVER=1
fi
if [[ "$PD_LEFTOVER" -eq 1 ]]; then
  echo -e "     ${CYAN}Fix:${NC} Run bash clean-pd.sh to reset"
else
  check_pass "No leftover P/D deployments"
fi

########################################################################
header "10. No Stale Node Labels"
########################################################################
LABELED_NODES=$(oc get nodes -l llm-d.ai/role -o name 2>/dev/null | wc -l | tr -d ' ')
if [[ "$LABELED_NODES" -gt 0 ]]; then
  check_fail "${LABELED_NODES} node(s) still have llm-d.ai/role label"
  echo -e "     ${CYAN}Fix:${NC} Run bash clean-pd.sh to reset"
else
  check_pass "No nodes have llm-d.ai/role labels"
fi

########################################################################
header "11. Worker Nodes"
########################################################################
WORKER_COUNT=$(oc get nodes \
  -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/master' \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$WORKER_COUNT" -ge 2 ]]; then
  check_pass "${WORKER_COUNT} dedicated worker nodes available"
else
  check_warn "Only ${WORKER_COUNT} dedicated worker node(s) — this exercise requires 2 for P/D placement"
  echo -e "     ${CYAN}Note:${NC} Provision an OCP cluster with at least two dedicated worker nodes"
fi

########################################################################
header "12. Connectivity Test"
########################################################################
if [[ -n "${ROUTE_HOST:-}" ]]; then
  HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' \
    "https://${ROUTE_HOST}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"prereq check"}],"max_tokens":1}' \
    2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "200" ]]; then
    check_pass "Gateway request returned HTTP 200"
  else
    check_fail "Gateway request returned HTTP ${HTTP_CODE} (expected 200)"
    echo -e "     ${CYAN}Fix:${NC} Check that simulator pods are Running and EPP is Available"
  fi
else
  check_warn "Skipping connectivity test (no route host found)"
fi

########################################################################
# Summary
########################################################################
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
TOTAL=$((PASS + FAIL + WARN))
echo -e "${BOLD}Results:${NC} ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${WARN} warnings${NC} (${TOTAL} total)"

if [[ "$FAIL" -eq 0 && "$WARN" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}Exercise prerequisites met — ready to begin.${NC}"
elif [[ "$FAIL" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}Exercise prerequisites met${NC} ${YELLOW}(with warnings).${NC}"
else
  echo -e "${RED}${BOLD}Fix the ${FAIL} failure(s) above before starting this exercise.${NC}"
  echo -e "${CYAN}If you have run this exercise previously and want to reset, run:${NC}"
  echo -e "  bash clean-pd.sh"
fi
echo ""

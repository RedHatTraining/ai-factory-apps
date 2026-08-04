#!/usr/bin/env bash
#
# check-scale-reqs.sh — Verify baseline cluster state before starting scale exercise.
#
# Checks:
#   1. Cluster access
#   2. Lab namespace exists
#   3. Simulator deployment (3 replicas, Available)
#   4. EPP deployment (Available)
#   5. Gateway deployment and route
#   6. EnvoyFilters (ext_proc + ORIGINAL_DST)
#   7. InferencePool exists
#   8. EPP config is baseline (no flowControl or saturationDetector)
#   9. No leftover scaling resources (ScaledObject, HPA, VA, PrometheusRule)
#  10. No leftover flow control resources (InferenceObjectives)
#  11. No leftover KEDA auth resources
#  12. KEDA operator available
#  13. Connectivity test (request through gateway returns 200)
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
echo -e "${BOLD}Scale Exercise Prerequisite Check${NC}"
echo "Verifying cluster state before starting the scale exercise"

########################################################################
header "1. Cluster Access"
########################################################################
if ! oc whoami &>/dev/null; then
  fail "Not logged in to OpenShift"
  echo -e "     ${CYAN}Fix:${NC} oc login <cluster-api-url> -u admin"
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
  echo -e "     ${CYAN}Fix:${NC} Complete the install exercise first."
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
    echo -e "     ${CYAN}Fix:${NC} Complete the install exercise first."
  fi
else
  check_fail "Simulator deployment llm-d-sim not found"
  echo -e "     ${CYAN}Fix:${NC} Complete the install exercise first."
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
    echo -e "     ${CYAN}Fix:${NC} oc delete pod -n $NS -l app=llm-d-sim-epp"
  fi
else
  check_fail "EPP deployment llm-d-sim-epp not found"
  echo -e "     ${CYAN}Fix:${NC} Complete the install exercise first."
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
  echo -e "     ${CYAN}Fix:${NC} Complete the cache exercise first."
fi

ROUTE_HOST=$(oc get route llm-d-lab-gateway -n "$NS" \
  -o jsonpath='{.status.ingress[0].host}' 2>/dev/null)
if [[ -n "$ROUTE_HOST" ]]; then
  check_pass "Route llm-d-lab-gateway has host: ${ROUTE_HOST}"
else
  check_fail "Route llm-d-lab-gateway not found or has no host"
  echo -e "     ${CYAN}Fix:${NC} Complete the cache exercise first."
fi

########################################################################
header "6. EnvoyFilters"
########################################################################
if oc get envoyfilter llm-d-sim-extproc -n "$NS" &>/dev/null; then
  check_pass "EnvoyFilter llm-d-sim-extproc exists"
else
  check_fail "EnvoyFilter llm-d-sim-extproc not found"
  echo -e "     ${CYAN}Fix:${NC} Complete the cache exercise first."
fi

if oc get envoyfilter llm-d-original-dst -n "$NS" &>/dev/null; then
  check_pass "EnvoyFilter llm-d-original-dst exists"
else
  check_fail "EnvoyFilter llm-d-original-dst not found"
  echo -e "     ${CYAN}Fix:${NC} Complete the cache exercise first."
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
  echo -e "     ${CYAN}Fix:${NC} Complete the install exercise first."
fi

########################################################################
header "8. EPP Config (baseline)"
########################################################################
if oc get configmap llm-d-sim-plugins -n "$NS" &>/dev/null; then
  CONFIG=$(oc get configmap llm-d-sim-plugins -n "$NS" -o jsonpath='{.data.default-plugins\.yaml}' 2>/dev/null)
  if echo "$CONFIG" | grep -q 'flowControl'; then
    check_fail "EPP config has flowControl (leftover from a previous run)"
    echo -e "     ${CYAN}Fix:${NC} bash scripts/restore.sh"
  elif echo "$CONFIG" | grep -q 'saturationDetector'; then
    check_fail "EPP config has saturationDetector (leftover from a previous run)"
    echo -e "     ${CYAN}Fix:${NC} bash scripts/restore.sh"
  elif echo "$CONFIG" | grep -q 'queue-scorer'; then
    check_pass "EPP config is baseline (queue-scorer + kv-cache-utilization-scorer)"
  else
    check_warn "EPP config exists but has unexpected content"
    echo -e "     ${CYAN}Fix:${NC} bash scripts/restore.sh"
  fi
else
  check_fail "ConfigMap llm-d-sim-plugins not found"
  echo -e "     ${CYAN}Fix:${NC} Complete the install exercise first."
fi

########################################################################
header "9. No Leftover Scaling Resources"
########################################################################
SCALE_LEFTOVER=0
if oc get scaledobject llm-d-sim-keda -n "$NS" &>/dev/null 2>&1; then
  check_fail "Leftover ScaledObject llm-d-sim-keda found"
  SCALE_LEFTOVER=1
fi
if [[ $(oc get hpa -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ') -gt 0 ]]; then
  check_fail "Leftover HPA(s) found"
  SCALE_LEFTOVER=1
fi
if oc get va llm-d-sim-va -n "$NS" &>/dev/null 2>&1; then
  check_fail "Leftover VariantAutoscaling llm-d-sim-va found"
  SCALE_LEFTOVER=1
fi
if oc get prometheusrule vllm-metrics-alias -n "$NS" &>/dev/null 2>&1; then
  check_fail "Leftover PrometheusRule vllm-metrics-alias found"
  SCALE_LEFTOVER=1
fi
if [[ "$SCALE_LEFTOVER" -eq 1 ]]; then
  echo -e "     ${CYAN}Fix:${NC} bash scripts/restore.sh"
else
  check_pass "No leftover scaling resources"
fi

########################################################################
header "10. No Leftover Flow Control Resources"
########################################################################
IO_COUNT=$(oc get inferenceobjective -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$IO_COUNT" -gt 0 ]]; then
  check_fail "${IO_COUNT} leftover InferenceObjective(s) found"
  echo -e "     ${CYAN}Fix:${NC} bash scripts/restore.sh"
else
  check_pass "No leftover InferenceObjectives"
fi

########################################################################
header "11. No Leftover KEDA Auth Resources"
########################################################################
KEDA_LEFTOVER=0
if oc get clustertriggerauthentication ai-inference-keda-thanos &>/dev/null 2>&1; then
  check_fail "Leftover ClusterTriggerAuthentication ai-inference-keda-thanos found"
  KEDA_LEFTOVER=1
fi
if oc get secret keda-metrics-reader-token -n openshift-keda &>/dev/null 2>&1; then
  check_fail "Leftover Secret keda-metrics-reader-token found"
  KEDA_LEFTOVER=1
fi
if [[ "$KEDA_LEFTOVER" -eq 1 ]]; then
  echo -e "     ${CYAN}Fix:${NC} bash scripts/restore.sh"
else
  check_pass "No leftover KEDA auth resources"
fi

########################################################################
header "12. KEDA Operator"
########################################################################
KEDA_NS="openshift-keda"
if oc get deployment -n "$KEDA_NS" --no-headers 2>/dev/null | grep -q 'keda'; then
  check_pass "KEDA operator deployment found in $KEDA_NS"
else
  check_warn "KEDA operator not found in $KEDA_NS"
  echo -e "     ${CYAN}Note:${NC} KEDA is required for the ScaledObject to work."
  echo -e "     ${CYAN}Fix:${NC} Install the Custom Metrics Autoscaler operator from OperatorHub."
fi

########################################################################
header "13. Connectivity Test"
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
  echo -e "${GREEN}${BOLD}Scale exercise prerequisites met — ready to begin.${NC}"
elif [[ "$FAIL" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}Scale exercise prerequisites met${NC} ${YELLOW}(with warnings).${NC}"
else
  echo -e "${RED}${BOLD}Fix the ${FAIL} failure(s) above before starting this exercise.${NC}"
  echo -e "${CYAN}If you have run this exercise previously and want to reset, run:${NC}"
  echo -e "  bash scripts/restore.sh"
fi
echo ""

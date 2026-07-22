#!/bin/bash
#
# cache-reset.sh — Reset the environment to the state after the intro GE
#
# Removes all resources created during the cache GE (partial or complete):
#   - Gateway, HTTPRoute, Route, EnvoyFilters, DestinationRule (step 2)
#   - EnvoyFilter llm-d-original-dst (step 3)
#   - Injected fake metrics (step 4)
#   - KV cache simulator patches and curl-helper pod (step 5)
#   - prefix-cache-scorer EPP configuration (step 6)
#
# After running this script, the environment matches the end of the
# intro GE: simulator stack running with baseline configuration,
# no Gateway or networking resources.
#
# Idempotent — safe to run at any point during or after the cache GE.
#
# Usage:
#   bash scripts/cache-reset.sh
#
set -euo pipefail

NAMESPACE="llm-d-lab"

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
# Pre-flight
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

if ! oc get ns "${NAMESPACE}" &>/dev/null 2>&1; then
  fail "Namespace ${NAMESPACE} does not exist. Run the intro GE first."
  exit 1
fi
ok "Namespace ${NAMESPACE} exists"

###############################################################################
# 1 — Delete curl-helper pod (step 5/6)
###############################################################################

step "1. Delete helper pod"

oc delete pod curl-helper -n "${NAMESPACE}" \
  --ignore-not-found --force --grace-period=0 2>/dev/null \
  && ok "Deleted curl-helper pod" \
  || ok "curl-helper pod not found"

###############################################################################
# 2 — Remove networking resources (steps 2-3)
###############################################################################

step "2. Remove networking resources"

oc delete envoyfilter llm-d-original-dst -n "${NAMESPACE}" \
  --ignore-not-found 2>/dev/null \
  && ok "Deleted EnvoyFilter llm-d-original-dst" \
  || ok "EnvoyFilter llm-d-original-dst not found"

oc delete envoyfilter llm-d-sim-extproc -n "${NAMESPACE}" \
  --ignore-not-found 2>/dev/null \
  && ok "Deleted EnvoyFilter llm-d-sim-extproc" \
  || ok "EnvoyFilter llm-d-sim-extproc not found"

oc delete destinationrule llm-d-sim-epp -n "${NAMESPACE}" \
  --ignore-not-found 2>/dev/null \
  && ok "Deleted DestinationRule llm-d-sim-epp" \
  || ok "DestinationRule llm-d-sim-epp not found"

oc delete httproute llm-d-sim-route -n "${NAMESPACE}" \
  --ignore-not-found 2>/dev/null \
  && ok "Deleted HTTPRoute llm-d-sim-route" \
  || ok "HTTPRoute llm-d-sim-route not found"

oc delete route llm-d-lab-gateway -n "${NAMESPACE}" \
  --ignore-not-found 2>/dev/null \
  && ok "Deleted Route llm-d-lab-gateway" \
  || ok "Route llm-d-lab-gateway not found"

oc delete gateway llm-d-lab-gateway -n "${NAMESPACE}" \
  --ignore-not-found 2>/dev/null \
  && ok "Deleted Gateway llm-d-lab-gateway" \
  || ok "Gateway llm-d-lab-gateway not found"

oc delete configmap llm-d-lab-gateway-config -n "${NAMESPACE}" \
  --ignore-not-found 2>/dev/null \
  && ok "Deleted ConfigMap llm-d-lab-gateway-config" \
  || ok "ConfigMap llm-d-lab-gateway-config not found"

###############################################################################
# 3 — Restore simulator deployment to baseline (steps 5-6)
###############################################################################

step "3. Restore simulator to baseline"

info "Patching simulator deployment..."
oc patch deployment llm-d-sim -n "${NAMESPACE}" --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/args","value":[
    "--port=8000",
    "--model=Qwen/Qwen2.5-0.5B-Instruct",
    "--render-url=http://localhost:8082",
    "--mode=random",
    "--time-to-first-token=500ms",
    "--inter-token-latency=50ms",
    "--dataset-path=/data/sharegpt-500.sqlite3",
    "--dataset-in-memory",
    "--fake-metrics={\"kv-cache-usage\":0,\"running-requests\":0,\"waiting-requests\":0}"
  ]}
]' 2>/dev/null && ok "Simulator args restored" || ok "Simulator args already at baseline"

ENV_JSON=$(oc get deployment llm-d-sim -n "${NAMESPACE}" \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{" "}{end}' 2>/dev/null || true)

POD_IP_INDEX=""
IDX=0
for name in ${ENV_JSON}; do
  if [[ "${name}" == "POD_IP" ]]; then
    POD_IP_INDEX="${IDX}"
    break
  fi
  IDX=$((IDX + 1))
done

if [[ -n "${POD_IP_INDEX}" ]]; then
  oc patch deployment llm-d-sim -n "${NAMESPACE}" --type=json \
    -p="[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/env/${POD_IP_INDEX}\"}]" 2>/dev/null \
    && ok "Removed POD_IP env var" \
    || warn "Could not remove POD_IP env var"
else
  ok "POD_IP env var not present"
fi

info "Waiting for simulator rollout..."
oc rollout status deployment/llm-d-sim -n "${NAMESPACE}" --timeout=600s
ok "Simulator pods rolled out"

###############################################################################
# 4 — Restore EPP configuration to baseline (step 6)
###############################################################################

step "4. Restore EPP configuration"

oc create configmap llm-d-sim-plugins -n "${NAMESPACE}" \
  --from-literal=default-plugins.yaml='apiVersion: inference.networking.x-k8s.io/v1alpha1
kind: EndpointPickerConfig
plugins:
  - type: queue-scorer
  - type: kv-cache-utilization-scorer
schedulingProfiles:
  - name: default
    plugins:
      - pluginRef: queue-scorer
        weight: 2
      - pluginRef: kv-cache-utilization-scorer
        weight: 2' \
  --dry-run=client -o yaml | oc apply -f -
ok "EPP ConfigMap restored to baseline"

info "Restarting EPP..."
oc delete pod -l app=llm-d-sim-epp -n "${NAMESPACE}" 2>/dev/null || true
oc wait --for=condition=Ready pod -l app=llm-d-sim-epp \
  -n "${NAMESPACE}" --timeout=120s
ok "EPP restarted"

###############################################################################
# 5 — Verify baseline state
###############################################################################

step "5. Verify baseline"

SIM_READY=$(oc get deployment llm-d-sim -n "${NAMESPACE}" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "${SIM_READY}" -ge 3 ]]; then
  ok "Simulator: ${SIM_READY}/3 replicas ready"
else
  warn "Simulator: ${SIM_READY}/3 replicas ready — pods may still be starting"
fi

EPP_READY=$(oc get deployment llm-d-sim-epp -n "${NAMESPACE}" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "${EPP_READY}" -ge 1 ]]; then
  ok "EPP: ${EPP_READY}/1 replicas ready"
else
  warn "EPP: ${EPP_READY}/1 replicas ready — pod may still be starting"
fi

POOL_EXISTS=$(oc get inferencepool llm-d-sim-pool -n "${NAMESPACE}" \
  --no-headers 2>/dev/null | wc -l)
if [[ "${POOL_EXISTS}" -gt 0 ]]; then
  ok "InferencePool llm-d-sim-pool exists"
else
  warn "InferencePool llm-d-sim-pool not found"
fi

GW_EXISTS=$(oc get gateway llm-d-lab-gateway -n "${NAMESPACE}" \
  --no-headers 2>/dev/null | wc -l)
if [[ "${GW_EXISTS}" -eq 0 ]]; then
  ok "No Gateway resources (expected)"
else
  warn "Gateway still exists — may need manual cleanup"
fi

EPP_CONFIG=$(oc logs deploy/llm-d-sim-epp -n "${NAMESPACE}" 2>/dev/null \
  | grep 'Loaded raw configuration' | tail -1 || true)
if echo "${EPP_CONFIG}" | grep -q 'prefix-cache-scorer'; then
  warn "EPP still shows prefix-cache-scorer — may need another restart"
else
  ok "EPP configuration: baseline (queue-scorer + kv-cache-utilization-scorer)"
fi

###############################################################################
# Done
###############################################################################

step "Done"
echo ""
echo -e "${GREEN}Cache GE reset complete.${NC}"
echo -e "The environment matches the end of the intro GE."
echo -e "You can now start the cache GE from step 1."
echo ""

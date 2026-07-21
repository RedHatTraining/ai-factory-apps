#!/bin/bash
#
# enable-kvcache.sh — Enable prefix caching on the simulator
#
# Patches the simulator deployment with:
#   --enable-kvcache, --kv-cache-size=256, --block-size=16,
#   --prefill-time-per-token=20ms, --prefill-overhead=100ms
#
# Waits for the rollout to complete before returning.
#
set -euo pipefail

NAMESPACE="llm-d-lab"

echo "Patching simulator deployment to enable KV cache..."

oc patch deployment llm-d-sim -n "${NAMESPACE}" --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{
    "name":"POD_IP",
    "valueFrom":{"fieldRef":{"fieldPath":"status.podIP"}}
  }},
  {"op":"replace","path":"/spec/template/spec/containers/0/args","value":[
    "--port=8000",
    "--model=Qwen/Qwen2.5-0.5B-Instruct",
    "--render-url=http://localhost:8082",
    "--mode=random",
    "--prefill-time-per-token=20ms",
    "--prefill-overhead=100ms",
    "--inter-token-latency=50ms",
    "--dataset-path=/data/sharegpt-500.sqlite3",
    "--dataset-in-memory",
    "--enable-kvcache",
    "--kv-cache-size=256",
    "--block-size=16",
    "--fake-metrics={\"kv-cache-usage\":0,\"running-requests\":0,\"waiting-requests\":0}"
  ]}
]'

echo ""
echo "Waiting for rollout (this takes about 2 minutes)..."
oc rollout status deployment/llm-d-sim -n "${NAMESPACE}" --timeout=600s

echo ""
echo "Verifying KV cache is active..."
POD_IP=$(oc get pods -n "${NAMESPACE}" -l app=llm-d-sim --no-headers \
  -o custom-columns=IP:.status.podIP | head -1)

oc exec deploy/llm-d-sim-epp -n "${NAMESPACE}" -- \
  curl -s "http://${POD_IP}:8000/metrics" 2>/dev/null \
  | grep -E 'cache_config_info|kv_cache_usage'

echo ""
echo "KV cache enabled successfully."

#!/bin/bash
# Deploy a custom EPP image that handles P/D
# and a curl helper pod

set -euo pipefail

echo "=== Deploying curl helper pod ==="

oc run helper -n llm-d-lab --image=curlimages/curl:latest \
  --restart=Never --command -- sleep 3600
oc wait pod/helper -n llm-d-lab --for=condition=Ready --timeout=60s

echo "=== Deploying custom EPP ==="

oc set image deployment/llm-d-sim-epp -n llm-d-lab \
  epp=quay.io/rsriniva/llm-d-epp:3a31761

oc patch deployment llm-d-sim-epp -n llm-d-lab --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/args",
   "value":[
     "--pool-name=llm-d-sim-pool",
     "--pool-namespace=llm-d-lab",
     "--pool-group=inference.networking.k8s.io",
     "--config-file=/config/default-plugins.yaml",
     "--zap-encoder=json",
     "--secure-serving=false",
     "--metrics-endpoint-auth=false",
     "--tracing=false",
     "-v=4"
   ]}
]'

oc rollout status deployment/llm-d-sim-epp -n llm-d-lab --timeout=120s

echo "=== Enable debug logging on the decode pods sidecar container ==="

oc patch deployment llm-d-sim-decode -n llm-d-lab --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/args",
   "value":[
     "--port=8000","--vllm-port=8200","--kv-connector=nixlv2",
     "--secure-proxy=false","--zap-encoder=json","--zap-log-level=4"
   ]}
]'

oc rollout status deployment/llm-d-sim-decode -n llm-d-lab --timeout=600s
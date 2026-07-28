#!/bin/bash

# Establish a baseline by sending requests with same prompts
# and check the response header for which pod handled the request

set -euo pipefail

ROUTE_URL=$(oc get route llm-d-lab-gateway -n llm-d-lab -o jsonpath='{.status.ingress[0].host}')

echo ""
echo "Sending requests with default EPP configuration (no disaggregation)..."
echo ""
for i in $(seq 1 10); do
  pod=$(curl -sk "https://${ROUTE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"Qwen/Qwen2.5-0.5B-Instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"Dummy request\"}],\"max_tokens\":5}" \
    -D - 2>/dev/null | grep -i 'x-inference-pod' | awk '{print $2}' | tr -d '\r')
  echo "  Request $i → $pod"
done
echo ""

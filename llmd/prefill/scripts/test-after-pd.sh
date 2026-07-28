#!/bin/bash

# Test by sending multiple requests with same prompt after EPP disaggregation config
# and check the response header for which pod handled the request

set -euo pipefail

ROUTE_URL=$(oc get route llm-d-lab-gateway -n llm-d-lab -o jsonpath='{.status.ingress[0].host}')

echo ""
echo "Sending requests with disagg config..."
echo ""
for i in $(seq 1 10); do
  pod=$(curl -sk "https://${ROUTE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"Qwen/Qwen2.5-0.5B-Instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"Test prompt\"}],\"max_tokens\":5}" \
    -D - 2>/dev/null | grep -i 'x-inference-pod' | awk '{print $2}' | tr -d '\r')
  echo "  Request $i → $pod"
done
echo ""

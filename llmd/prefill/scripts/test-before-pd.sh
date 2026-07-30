#!/bin/bash

# Establish a baseline by sending requests with same prompts
# and check the response header for which pod handled the request

set -euo pipefail

ROUTE_URL=$(oc get route llm-d-lab-gateway -n llm-d-lab -o jsonpath='{.status.ingress[0].host}')

echo ""
echo "Sending requests with default EPP configuration (no disaggregation)..."
echo ""

# Send 4 concurrent requests
echo ""
for i in $(seq 1 4); do
  curl -sk -D /tmp/h_conc_baseline_$i \
    -w "  Request ${i}: TTFB=%{time_starttransfer}s\n" -o /dev/null \
    "https://${ROUTE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"Qwen/Qwen2.5-0.5B-Instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"Concurrent baseline $i\"}],\"max_tokens\":1,\"stream\":true}" \
    2>/dev/null &
done
wait
echo ""
echo "Request distribution:"
for i in $(seq 1 4); do
  pod=$(grep -i 'x-inference-pod' /tmp/h_conc_baseline_$i 2>/dev/null \
    | awk '{print $2}' | tr -d '\r')
  echo "  Request $i → ${pod}"
done
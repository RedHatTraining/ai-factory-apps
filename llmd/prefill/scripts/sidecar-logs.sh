#!/bin/bash
# Query Prefill/Decode Pod Metrics

set -euo pipefail
echo ""

ROUTE_URL=$(oc get route llm-d-lab-gateway -n llm-d-lab \
  -o jsonpath='{.status.ingress[0].host}')

curl -sk "https://${ROUTE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"Show P/D logs"}],"max_tokens":10}' \
  > /dev/null

echo "=== Decode sidecar logs (last request) ==="
oc logs -l llm-d.ai/role=decode -n llm-d-lab \
  -c routing-sidecar --tail=10 2>/dev/null \
  | grep -E "using P/D|running NIXL|sending prefill|sending request to decoder" \
  | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line)
        print(f'  {d[\"msg\"]}  {d.get(\"to\", d.get(\"url\", \"\"))}')
    except: print(f'  {line.strip()}')
"
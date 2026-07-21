#!/usr/bin/env bash
# Test llm-d simulator inference by sending a chat completion request
# Usage: ./test-inference.sh [port] [prompt] [max_tokens]

set -euo pipefail

# Configuration
PORT="${1:-8000}"
PROMPT="${2:-What is Kubernetes?}"
MAX_TOKENS="${3:-50}"
MODEL="Qwen/Qwen2.5-0.5B-Instruct"

echo "Checking port-forward is active on port ${PORT}..."
if ! curl -s "http://localhost:${PORT}/v1/models" > /dev/null 2>&1; then
    echo "✗ Port-forward is not active on port ${PORT}. Start it first with: ./port-forwarding.sh"
    exit 1
fi
echo "✓ Port-forward is active"

echo "Sending inference request to http://localhost:${PORT}/v1/chat/completions"
echo "Prompt: ${PROMPT}"
echo "Max tokens: ${MAX_TOKENS}"
echo ""

# Send inference request
RESPONSE=$(curl -s "http://localhost:${PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"${PROMPT}\"}],\"max_tokens\":${MAX_TOKENS}}")

if echo "${RESPONSE}" | python3 -m json.tool; then
    echo ""
    echo "✓ Inference request successful"
    exit 0
else
    echo ""
    echo "✗ Inference request failed"
    exit 1
fi

#!/usr/bin/env bash
# Test llm-d simulator inference by sending a chat completion request
# Usage: ./test-inference.sh [namespace] [deployment] [port] [prompt] [max_tokens]

set -euo pipefail

# Configuration
NAMESPACE="${1:-llm-d-lab}"
DEPLOYMENT="${2:-llm-d-sim}"
PORT="${3:-8000}"
PROMPT="${4:-What is Kubernetes?}"
MAX_TOKENS="${5:-50}"
MODEL="Qwen/Qwen2.5-0.5B-Instruct"

echo "Starting port-forward to ${DEPLOYMENT} in namespace ${NAMESPACE}..."

# Start port-forward in background
oc port-forward -n "${NAMESPACE}" "deploy/${DEPLOYMENT}" "${PORT}:${PORT}" &
PF_PID=$!

# Ensure port-forward is killed on exit
trap "kill ${PF_PID} 2>/dev/null || true" EXIT

# Wait for port-forward to be ready
echo "Waiting for port-forward to be ready..."
sleep 3

# Test if port is accessible
MAX_RETRIES=5
RETRY=0
while ! curl -s "http://localhost:${PORT}/v1/models" > /dev/null 2>&1; do
    RETRY=$((RETRY + 1))
    if [ ${RETRY} -ge ${MAX_RETRIES} ]; then
        echo "✗ Port-forward failed to become ready after ${MAX_RETRIES} attempts"
        exit 1
    fi
    echo "Port not ready, retrying (${RETRY}/${MAX_RETRIES})..."
    sleep 1
done

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

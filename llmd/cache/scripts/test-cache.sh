#!/bin/bash
#
# test-cache.sh — Send a request directly to a simulator pod and show cache metrics
#
# Usage:
#   bash scripts/test-cache.sh              # Send a request (creates helper pod if needed)
#   bash scripts/test-cache.sh -p "prompt"  # Send a custom prompt
#
# Shows: prompt_tokens, cached_tokens, and TTFT for each request.
# Run twice with the same prompt to compare cold (no cache) vs warm (cached) TTFT.
#
set -euo pipefail

NAMESPACE="llm-d-lab"
MODEL="Qwen/Qwen2.5-0.5B-Instruct"
PROMPT="Explain how prefix caching works in vLLM inference serving systems."

while [[ $# -gt 0 ]]; do
  case $1 in
    -p) PROMPT=$2; shift 2 ;;
    *) echo "Usage: $0 [-p prompt]" >&2; exit 1 ;;
  esac
done

if ! oc get pod curl-helper -n "${NAMESPACE}" &>/dev/null; then
  echo "Creating helper pod for in-cluster testing..."
  oc run curl-helper -n "${NAMESPACE}" --image=curlimages/curl:latest \
    --restart=Never --command -- sleep 86400
  oc wait pod/curl-helper -n "${NAMESPACE}" --for=condition=Ready --timeout=60s
  echo ""
fi

IP=$(oc get pods -n "${NAMESPACE}" -l app=llm-d-sim --no-headers \
  -o custom-columns=IP:.status.podIP | head -1)

DISPLAY_PROMPT="${PROMPT:0:40}"
[ ${#PROMPT} -gt 40 ] && DISPLAY_PROMPT="${DISPLAY_PROMPT}..."

echo "Sending request to pod at ${IP}..."
echo "Prompt: \"${DISPLAY_PROMPT}\""
echo ""

BODY="{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"${PROMPT}\"}],\"max_tokens\":3}"

RESPONSE=$(oc exec curl-helper -n "${NAMESPACE}" -- \
  curl -s -w '\nTTFT: %{time_starttransfer}s' \
  -X POST "http://${IP}:8000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "${BODY}" 2>/dev/null)

PROMPT_TOKENS=$(echo "${RESPONSE}" | grep -oE '"prompt_tokens":[0-9]+' | grep -oE '[0-9]+' || echo "?")
CACHED_TOKENS=$(echo "${RESPONSE}" | grep -oE '"cached_tokens":[0-9]+' | grep -oE '[0-9]+' || echo "?")
TTFT=$(echo "${RESPONSE}" | grep -oE 'TTFT: [0-9.]+' | grep -oE '[0-9.]+' || echo "?")

echo "  prompt_tokens:  ${PROMPT_TOKENS}"
echo "  cached_tokens:  ${CACHED_TOKENS}"
echo "  TTFT:           ${TTFT}s"

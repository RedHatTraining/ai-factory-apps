#!/usr/bin/env bash
set -euo pipefail

# Verify that the endpoint and token environment variables are set
if [ -z "${ENDPOINT:-}" ] || [ -z "${TOKEN:-}" ]; then
    echo "Make sure the ENDPOINT and TOKEN environment variables are set"
    exit 1
fi

PROMPT=$1

# Verify that the prompt is provided
if [ -z "${PROMPT:-}" ]; then
    echo "Usage: $0 <prompt>"
    exit 1
fi

curl -s "${ENDPOINT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d "{
    \"model\": \"qwen3-06b-v1\",
    \"messages\": [
      {\"role\": \"system\",
       \"content\": \"You are a helpful assistant. Provide direct, concise answers without showing your reasoning process.\"},
      {\"role\": \"user\",
       \"content\": \"${PROMPT}\"}
    ],
    \"max_tokens\": 1200,
    \"temperature\": 0.7,
    \"top_p\": 0.9
  }" | python -m json.tool

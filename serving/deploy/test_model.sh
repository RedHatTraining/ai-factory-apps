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
  -d '{
    "model": "qwen3-06b-v1",
    "messages": [
      {"role": "user",
       "content": "${PROMPT}"}
    ],
    "max_tokens": 200
  }' | python -m json.tool
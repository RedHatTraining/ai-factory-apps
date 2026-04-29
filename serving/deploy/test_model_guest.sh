#!/usr/bin/env bash
set -euo pipefail

# Verify that the endpoint environment variable is set
if [ -z "${ENDPOINT:-}" ]; then
    echo "Make sure the ENDPOINT environment variable is set"
    exit 1
fi

PROMPT=$1

# Verify that the prompt is provided
if [ -z "${PROMPT:-}" ]; then
    echo "Usage: $0 <prompt>"
    exit 1
fi

curl "${ENDPOINT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-06b-v1",
    "messages": [{"role": "user", "content": "${PROMPT}"}],
    "max_tokens": 16
  }'
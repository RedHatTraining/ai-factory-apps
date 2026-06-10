#!/usr/bin/env bash
set -euo pipefail

MODEL="granite-3-2b"
ENDPOINT="http://localhost:8080"
CONCURRENT=20

PROMPT="Explain in great detail the history of artificial intelligence from its theoretical foundations in the 1950s through modern large language models. Cover the key milestones, breakthroughs, and setbacks along the way. Discuss the contributions of Alan Turing, John McCarthy, Marvin Minsky, Geoffrey Hinton, Yann LeCun, and other pioneers. Explain how neural networks evolved from perceptrons to deep learning architectures."

echo "Sending $CONCURRENT concurrent requests..."

for i in $(seq 1 "$CONCURRENT"); do
  curl -s "${ENDPOINT}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${MODEL}\",
      \"messages\": [{\"role\": \"user\", \"content\": \"${PROMPT}\"}],
      \"max_tokens\": 512
    }" > /dev/null 2>&1 &
done

echo "Waiting for all requests to complete..."
wait

echo "Load test complete."

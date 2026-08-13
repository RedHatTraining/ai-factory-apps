#!/bin/bash
set -euo pipefail

# Parse command-line arguments
CONCURRENT_MODE=false
if [[ "${1:-}" == "--concurrent" ]]; then
  CONCURRENT_MODE=true
  CONCURRENT_REQUESTS=5
  echo "[INFO] Running in CONCURRENT mode with $CONCURRENT_REQUESTS parallel requests"
fi

export ENDPOINT=$(oc get inferenceservice qwen3-06b-v1 -n serving-genai -o jsonpath='{.status.url}')
export TOKEN=$(oc get secret default-token-qwen3-06b-v1-sa -n serving-genai -o jsonpath='{.data.token}' | base64 -d)

echo "[INFO] Starting continuous inference for 3 minutes..."
echo "[INFO] Endpoint: $ENDPOINT"
echo "[INFO] Monitor GPU with: oc exec -n serving-genai deployment/qwen3-06b-v1-predictor -c kserve-container -- watch -n 1 nvidia-smi"
echo ""

END_TIME=$((SECONDS + 180))  # Run for 3 minutes (180 seconds)
COUNTER=0
SUCCESS_COUNT=0
FAILED_COUNT=0

PROMPTS=(
  "Explain the concept of artificial intelligence and its applications in modern technology"
  "Describe machine learning algorithms and how they learn from data patterns"
  "What are neural networks and how do they process information layer by layer"
  "Explain deep learning architectures and their advantages over traditional methods"
  "Describe natural language processing techniques used in text analysis"
  "How does computer vision enable machines to interpret visual information"
  "Explain reinforcement learning and how agents learn through trial and error"
  "What is supervised learning and how does it differ from unsupervised learning"
)

# Function to send a request and measure time
send_request() {
  local prompt="$1"
  local counter="$2"
  local start_time=$(date +%s.%N)

  if ./test_model.sh "$prompt" > /dev/null 2>&1; then
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    echo "[$counter] $(date +%H:%M:%S) - ✓ Success (${duration}s) - ${prompt:0:50}..."
    return 0
  else
    echo "[$counter] $(date +%H:%M:%S) - ⚠️  Failed - ${prompt:0:50}..."
    return 1
  fi
}

if [[ "$CONCURRENT_MODE" == true ]]; then
  # CONCURRENT MODE: Send multiple requests in parallel
  while [ $SECONDS -lt $END_TIME ]; do
    # Launch a batch of concurrent requests
    for i in $(seq 1 $CONCURRENT_REQUESTS); do
      COUNTER=$((COUNTER + 1))
      PROMPT_INDEX=$((COUNTER % 8))
      PROMPT="${PROMPTS[$PROMPT_INDEX]}"

      (
        if send_request "$PROMPT" "$COUNTER"; then
          echo "SUCCESS" > "/tmp/inference_${COUNTER}.result"
        else
          echo "FAILED" > "/tmp/inference_${COUNTER}.result"
        fi
      ) &
    done

    # Wait for all concurrent requests to complete
    wait

    # Count results
    for i in $(seq $((COUNTER - CONCURRENT_REQUESTS + 1)) $COUNTER); do
      if [[ -f "/tmp/inference_${i}.result" ]]; then
        if grep -q "SUCCESS" "/tmp/inference_${i}.result" 2>/dev/null; then
          SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
          FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
        rm -f "/tmp/inference_${i}.result"
      fi
    done

    # Small delay between batches
    sleep 2
  done
else
  # SEQUENTIAL MODE: Send one request at a time
  while [ $SECONDS -lt $END_TIME ]; do
    COUNTER=$((COUNTER + 1))
    PROMPT_INDEX=$((COUNTER % 8))
    PROMPT="${PROMPTS[$PROMPT_INDEX]}"

    if send_request "$PROMPT" "$COUNTER"; then
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
      FAILED_COUNT=$((FAILED_COUNT + 1))
    fi

    # Small delay between requests
    sleep 1
  done
fi

echo ""
echo "[DONE] Completed $COUNTER inference requests in 3 minutes"
echo "[STATS] Successful: $SUCCESS_COUNT | Failed: $FAILED_COUNT"
if [[ $COUNTER -gt 0 ]]; then
  SUCCESS_RATE=$(echo "scale=1; $SUCCESS_COUNT * 100 / $COUNTER" | bc)
  echo "[STATS] Success rate: ${SUCCESS_RATE}%"
fi

#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="monitoring-metrics"
MODEL_NAME="granite-monitor"
DEFAULT_COUNT=10

COUNT="${1:-$DEFAULT_COUNT}"
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
  echo "Usage: $0 [num_requests]  (default: $DEFAULT_COUNT)"
  exit 1
fi

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in to OpenShift."; exit 1; }

POD=$(oc get pod -n "$NAMESPACE" \
  -l serving.kserve.io/inferenceservice="$MODEL_NAME" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) \
  || { echo "[FAIL] No pod found for InferenceService $MODEL_NAME in $NAMESPACE."; exit 1; }

QUESTIONS=(
  "What is Kubernetes?"
  "What is a container runtime?"
  "What is Prometheus?"
  "What is GPU memory utilization?"
  "What is a service mesh?"
  "What is model inference?"
  "What is a KV cache?"
  "What is time to first token?"
  "What is a vector database?"
  "What is retrieval augmented generation?"
)
BATCH_SIZE=${#QUESTIONS[@]}
BATCHES=$(( (COUNT + BATCH_SIZE - 1) / BATCH_SIZE ))
TOTAL=$((BATCHES * BATCH_SIZE))

echo "[INFO] Sending $TOTAL requests ($BATCHES batches of $BATCH_SIZE) to $MODEL_NAME via pod $POD..."

sent=0
for ((b=1; b<=BATCHES; b++)); do
  echo "[INFO] Batch $b/$BATCHES..."
  for i in "${!QUESTIONS[@]}"; do
    Q="${QUESTIONS[$i]}"
    sent=$((sent + 1))
    oc exec -n "$NAMESPACE" "$POD" -c kserve-container -- \
      curl -s http://localhost:8080/v1/chat/completions \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"${Q} Answer in one sentence.\"}],\"max_tokens\":30}" \
      > /dev/null
    echo "  Request $sent/$TOTAL complete."
  done
done

echo "[OK] Load test complete — $TOTAL requests sent."

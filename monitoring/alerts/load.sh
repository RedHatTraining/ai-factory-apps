#!/bin/bash
# load.sh — Generate inference load to trigger Prometheus alerts
#
# Sends concurrent requests INSIDE the model pod using oc exec.
# All concurrency happens inside the pod — the student's laptop
# only runs a single oc exec per batch, so laptop performance
# does not matter.
#
# Each request includes a unique suffix to defeat vLLM's prefix
# caching, which would otherwise let repeated prompts complete
# instantly from cache.
#
# USAGE:
#
#   ./load.sh              # Default: 50 concurrent, 10 batches
#   ./load.sh 80 15        # Higher load
#   ./load.sh 30 5         # Light load for quick test
#
# STOPPING:
#
#   Press Ctrl+C to stop. After stopping, observe alerts
#   transition from Firing to Resolved in the OpenShift Console.

set -uo pipefail

CONCURRENCY="${1:-50}"
ITERATIONS="${2:-10}"
NAMESPACE="monitoring-metrics"
MODEL_NAME="granite-monitor"

cleanup() {
  echo ""
  echo "Stopping load test..."
  for pid in $(jobs -p 2>/dev/null); do kill "$pid" 2>/dev/null; done
  exit 0
}
trap cleanup INT TERM

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in to OpenShift."; exit 1; }

POD=$(oc get pod -n "$NAMESPACE" \
  -l serving.kserve.io/inferenceservice="$MODEL_NAME" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$POD" ]; then
  echo "[FAIL] No Running pod found for InferenceService $MODEL_NAME in $NAMESPACE."
  echo "Available pods:"
  oc get pods -n "$NAMESPACE" -l serving.kserve.io/inferenceservice="$MODEL_NAME" 2>/dev/null
  exit 1
fi

echo "============================================="
echo " LLM Load Test (in-cluster)"
echo "============================================="
echo " Pod:          $POD"
echo " Namespace:    $NAMESPACE"
echo " Model:        $MODEL_NAME"
echo " Concurrency:  $CONCURRENCY requests per batch"
echo " Iterations:   $ITERATIONS batches"
echo " Total:        $((CONCURRENCY * ITERATIONS)) requests"
echo " Max tokens:   1024 per request"
echo "============================================="
echo ""
echo "Starting load test in 3 seconds..."
echo "Press Ctrl+C to stop at any time."
echo ""
sleep 3

PROMPT="Write a complete, production-ready Python implementation of a red-black tree data structure. Include insert with rebalancing, delete with fixup, search, in-order traversal, and a verify method that checks all red-black tree invariants. Add comprehensive type hints, docstrings, and unit tests using pytest. Show the full code."
STAGGER=5
STARTED=$(date +%s)

echo "Batches overlap with ${STAGGER}s stagger to maintain sustained pressure."
echo ""

for i in $(seq 1 "$ITERATIONS"); do
  (
    RESULTS=$(oc exec "$POD" -n "$NAMESPACE" -c kserve-container -- sh -c "
      TMPFILE=\$(mktemp)
      for j in \$(seq 1 $CONCURRENCY); do
        UNIQUE=\"[Request \${j}, batch ${i}, id \$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo \$RANDOM\$RANDOM)]\"
        curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/v1/completions \
          -H 'Content-Type: application/json' \
          --max-time 300 \
          -d '{\"model\":\"$MODEL_NAME\",\"prompt\":\"\${UNIQUE} $PROMPT\",\"max_tokens\":1024,\"temperature\":0.7}' >> \$TMPFILE &
      done
      wait
      OK=\$(grep -c '^200$' \$TMPFILE || true)
      FAIL=\$(grep -cv '^200$' \$TMPFILE || true)
      rm -f \$TMPFILE
      echo \"\$OK \$FAIL\"
    " 2>/dev/null)
    OK=$(echo "$RESULTS" | awk '{print $1}')
    FAIL=$(echo "$RESULTS" | awk '{print $2}')
    ELAPSED=$(( $(date +%s) - STARTED ))
    if [ "${FAIL:-0}" -gt 0 ]; then
      echo "  Batch $i/$ITERATIONS done | ${OK:-0} ok, ${FAIL} failed | ${ELAPSED}s"
    else
      echo "  Batch $i/$ITERATIONS done | ${OK:-$CONCURRENCY} ok | ${ELAPSED}s"
    fi
  ) &

  ELAPSED=$(( $(date +%s) - STARTED ))
  echo "Batch $i/$ITERATIONS launched ($CONCURRENCY requests) | ${ELAPSED}s"

  if [ "$i" -lt "$ITERATIONS" ]; then
    sleep "$STAGGER"
  fi
done

echo ""
echo "All $ITERATIONS batches launched. Waiting for remaining requests..."
wait

FINISHED=$(date +%s)
TOTAL_DURATION=$((FINISHED - STARTED))
TOTAL_REQUESTS=$((CONCURRENCY * ITERATIONS))

echo ""
echo "============================================="
echo " Load Test Complete"
echo "============================================="
echo " Total requests: $TOTAL_REQUESTS"
echo " Duration:       ${TOTAL_DURATION}s"
echo "============================================="
echo ""

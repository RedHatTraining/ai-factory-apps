#!/usr/bin/env bash
# Port-forward to llm-d simulator and test the /v1/models endpoint
# Usage: ./port-forwading.sh [namespace] [deployment] [port] [endpoint]

set -euo pipefail

# Configuration
NAMESPACE="${1:-llm-d-lab}"
DEPLOYMENT="${2:-llm-d-sim}"
PORT="${3:-8000}"
ENDPOINT="${4:-/v1/models}"

echo "Starting port-forward to ${DEPLOYMENT} in namespace ${NAMESPACE}..."

# Start port-forward in background
oc port-forward -n "${NAMESPACE}" "deploy/${DEPLOYMENT}" "${PORT}:${PORT}" &
PF_PID=$!

# Ensure port-forward is killed on exit
trap "kill ${PF_PID} 2>/dev/null || true" EXIT

# Wait for port-forward to be ready (up to 10 seconds)
for i in $(seq 1 10); do
    curl -s -o /dev/null "http://localhost:${PORT}${ENDPOINT}" 2>/dev/null && break
    sleep 1
done

echo "Testing endpoint: http://localhost:${PORT}${ENDPOINT}"
echo ""

# Query the API endpoint
if curl -s "http://localhost:${PORT}${ENDPOINT}" | python3 -m json.tool; then
    echo ""
    echo "✓ Port-forward test successful"
    exit 0
else
    echo ""
    echo "✗ Port-forward test failed"
    exit 1
fi

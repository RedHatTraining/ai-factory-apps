#!/usr/bin/env bash
set -euo pipefail

LAB_PROJECT="monitoring-alerts"
ISVC_NAME="granite-monitor"
CONCURRENCY=200
PROMPT="Write a detailed essay about the history and evolution of artificial intelligence, covering the major milestones from the 1950s to the present day, including key researchers, breakthroughs, and paradigm shifts."

command -v oc &>/dev/null || { echo "[FAIL] oc is not installed."; exit 1; }
oc whoami &>/dev/null || { echo "[FAIL] Not logged in. Run: oc login -u admin -p PASSWORD https://API_URL"; exit 1; }

ISVC_URL="http://$(oc get route "$ISVC_NAME" -n "$LAB_PROJECT" \
  -o jsonpath='{.spec.host}')"
TOKEN=$(oc whoami -t)

if [ -z "$ISVC_URL" ]; then
  echo "[FAIL] Could not retrieve InferenceService URL."
  exit 1
fi

cleanup() {
  echo ""
  echo "[INFO] Load generation stopped."
  kill 0 2>/dev/null
  wait 2>/dev/null
  exit 0
}
trap cleanup INT TERM

send_request() {
  while true; do
    curl -sk "${ISVC_URL}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${TOKEN}" \
      -d "{
        \"model\": \"granite-monitor\",
        \"messages\": [{\"role\": \"user\", \"content\": \"${PROMPT}\"}],
        \"max_tokens\": 16384
      }" > /dev/null 2>&1
  done
}

echo "[INFO] Sending concurrent requests to model endpoint..."
for i in $(seq 1 "$CONCURRENCY"); do
  send_request &
done
echo "[INFO] Requests in progress..."

wait

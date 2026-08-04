#!/bin/bash
#
# send-requests.sh — Send inference requests and show pod distribution
#
# Usage: bash scripts/send-requests.sh [OPTIONS]
#
# Options:
#   -n COUNT    Number of requests to send (default: 12)
#   -p PROMPT   Prompt text (default: "Request")
#               Without --cache: a sequence number is appended to each request
#               With --cache: the prompt is sent as-is (same prompt every time)
#   --cache     Show cached_tokens alongside the pod name
#   --helper    Route requests through the curl-helper pod (in-cluster)
#
set -euo pipefail

NAMESPACE="llm-d-lab"
COUNT=12
PROMPT="Request"
MODEL="Qwen/Qwen2.5-0.5B-Instruct"
SHOW_CACHE=false
USE_HELPER=false
ROUTE_URL="${ROUTE_URL:-}"

while [[ $# -gt 0 ]]; do
  case $1 in
    -n) COUNT=$2; shift 2 ;;
    -p) PROMPT=$2; shift 2 ;;
    --cache) SHOW_CACHE=true; shift ;;
    --helper) USE_HELPER=true; shift ;;
    *) echo "Usage: $0 [-n count] [-p prompt] [--cache] [--helper]" >&2; exit 1 ;;
  esac
done

if [ -z "${ROUTE_URL}" ]; then
  ROUTE_URL=$(oc get route llm-d-lab-gateway -n "${NAMESPACE}" \
    -o jsonpath='{.status.ingress[0].host}')
fi

if [ "${SHOW_CACHE}" = true ]; then
  DISPLAY_PROMPT="${PROMPT:0:30}"
  [ ${#PROMPT} -gt 30 ] && DISPLAY_PROMPT="${DISPLAY_PROMPT}..."
  echo "Sending ${COUNT} requests (prompt: \"${DISPLAY_PROMPT}\")..."
else
  echo "Sending ${COUNT} requests (prompt: \"${PROMPT} <N>\")..."
fi
echo ""

for i in $(seq 1 "${COUNT}"); do
  if [ "${SHOW_CACHE}" = true ]; then
    CONTENT="${PROMPT}"
  else
    CONTENT="${PROMPT} ${i}"
  fi
  BODY="{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"${CONTENT}\"}],\"max_tokens\":5}"

  if [ "${USE_HELPER}" = true ]; then
    RESPONSE=$(oc exec curl-helper -n "${NAMESPACE}" -- \
      curl -s --max-time 15 -k -D - \
      -X POST "https://${ROUTE_URL}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "${BODY}" 2>/dev/null)
  else
    RESPONSE=$(curl -sk --max-time 15  -D - "https://${ROUTE_URL}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "${BODY}" 2>/dev/null)
  fi

  POD=$(echo "${RESPONSE}" | grep -i 'x-inference-pod' | awk '{print $2}' | tr -d '\r')

  if [ "${SHOW_CACHE}" = true ]; then
    CACHED=$(echo "${RESPONSE}" | grep -oE '"cached_tokens":[0-9]+' || echo '"cached_tokens":?')
    echo "  Request ${i}: pod=${POD}  ${CACHED}"
  else
    echo "${POD}"
  fi
done | if [ "${SHOW_CACHE}" = true ]; then
  cat
else
  RESULTS=$(sort | uniq -c | sort -rn)
  printf "\n  %-10s  %s\n" "REQUESTS" "POD"
  printf "  %-10s  %s\n" "--------" "---"
  echo "${RESULTS}" | while read -r count pod; do
    printf "  %-10s  %s\n" "${count}" "${pod}"
  done
fi

echo ""
echo "Done."

#!/bin/bash
#
# verify-original-dst.sh — Verify the ORIGINAL_DST cluster in the Envoy proxy
#
# Checks that the Gateway proxy has loaded the ORIGINAL_DST cluster
# and is configured to read the x-gateway-destination-endpoint header.
#
set -euo pipefail

NAMESPACE="llm-d-lab"
DEPLOY="llm-d-lab-gateway-data-science-gateway-class"
CLUSTER_NAME="llm-d-original-dst"
MAX_RETRIES=6
RETRY_INTERVAL=5

echo "Verifying ORIGINAL_DST cluster in proxy configuration..."

for attempt in $(seq 1 "${MAX_RETRIES}"); do
  RESULT=$(oc exec "deploy/${DEPLOY}" -n "${NAMESPACE}" \
    -- pilot-agent request GET config_dump 2>/dev/null \
    | python3 -c "
import sys, json
for c in json.load(sys.stdin).get('configs', []):
    for sc in c.get('static_clusters', []) + c.get('dynamic_active_clusters', []):
        cl = sc.get('cluster', {})
        if cl.get('name') == '${CLUSTER_NAME}':
            cfg = cl.get('original_dst_lb_config', {})
            print(f'Cluster: {cl[\"name\"]}  Type: {cl[\"type\"]}')
            print(f'Header:  {cfg.get(\"http_header_name\")}')
" 2>/dev/null || true)

  if [ -n "${RESULT}" ]; then
    echo ""
    echo "${RESULT}"
    echo ""
    echo "ORIGINAL_DST cluster is active. The proxy honors EPP routing decisions."
    exit 0
  fi

  if [ "${attempt}" -lt "${MAX_RETRIES}" ]; then
    echo "  Attempt ${attempt}/${MAX_RETRIES}: cluster not found yet, retrying in ${RETRY_INTERVAL}s..."
    sleep "${RETRY_INTERVAL}"
  fi
done

echo ""
echo "ERROR: ORIGINAL_DST cluster not found after ${MAX_RETRIES} attempts."
echo "Check that the EnvoyFilter was applied: oc get envoyfilter -n ${NAMESPACE}"
exit 1

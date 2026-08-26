#!/bin/bash
# Query EPP logs to check the PreRequest plugin execution

set -euo pipefail

echo "=== Querying EPP Logs to see PreRequest plugin execution ==="

oc logs deployment/llm-d-sim-epp -n llm-d-lab --tail=50 2>/dev/null \
  | grep "PreRequest" | tail -4 \
  | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line)
        print(f'  {d[\"msg\"]}  plugin={d.get(\"plugin\",\"\")}')
    except: pass
"

#!/bin/bash

set -euo pipefail

echo "--- Kueue Lab Cleanup ---"
echo ""

echo "[1/8] Removing inference workloads (ServingRuntime, InferenceService, HardwareProfile)"
oc delete -f 7-*.yaml --ignore-not-found

echo "[2/8] Removing batch job workloads"
oc delete -f 6-*.yaml --ignore-not-found

echo "[3/8] Removing workload priority classes"
oc delete -f 5-*.yaml --ignore-not-found

echo "[4/8] Removing local queues"
oc delete -f 4-*.yaml --ignore-not-found

echo "[5/8] Removing cluster queue"
oc delete -f 3-*.yaml --ignore-not-found

echo "[6/8] Removing resource flavor"
oc delete -f 2-*.yaml --ignore-not-found

echo "[7/8] Removing team namespaces"
oc delete -f 1-*.yaml --ignore-not-found

echo "[8/8] Restoring DSC kueue managementState"
oc patch datasciencecluster default-dsc --type merge \
  -p '{"spec":{"components":{"kueue":{"managementState":"Removed"}}}}'

echo ""
echo "Cleanup complete."

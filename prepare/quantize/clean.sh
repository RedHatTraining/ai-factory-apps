#!/bin/bash
set -euo pipefail

PROJECT="prepare-quantize"

echo "[INFO] Deleting inference services..."
oc delete inferenceservice --all -n ${PROJECT} 2>/dev/null || true

echo "[INFO] Deleting jobs..."
oc delete job --all -n ${PROJECT} 2>/dev/null || true

echo "[INFO] Deleting PVCs..."
oc delete pvc --all -n ${PROJECT} 2>/dev/null || true

echo "[INFO] Deleting project ${PROJECT}..."
oc delete project ${PROJECT} 2>/dev/null || true

echo ""
echo "[OK] Cleanup complete."

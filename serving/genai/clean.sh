#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_PROJECT="serving-genai"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }

command -v oc &>/dev/null  || { fail "oc is not installed."; exit 1; }
oc whoami &>/dev/null || { fail "Not logged in. Run: oc login -u admin -p PASSWORD https://API_URL"; exit 1; }

# ── 1. Clean InferenceServices with stale Model Registry finalizers ──────────

if oc get project "$LAB_PROJECT" &>/dev/null; then
  info "Checking for InferenceServices with Model Registry finalizers in $LAB_PROJECT..."

  ISVC_LIST=$(oc get inferenceservice -n "$LAB_PROJECT" -o name 2>/dev/null || true)

  if [[ -n "$ISVC_LIST" ]]; then
    for isvc in $ISVC_LIST; do
      ISVC_NAME=$(echo "$isvc" | cut -d'/' -f2)

      # Check if it has the model registry finalizer
      HAS_MR_FINALIZER=$(oc get inferenceservice "$ISVC_NAME" -n "$LAB_PROJECT" \
        -o jsonpath='{.metadata.finalizers}' 2>/dev/null | grep -c "modelregistry.opendatahub.io/finalizer" || true)

      if [[ "$HAS_MR_FINALIZER" -gt 0 ]]; then
        info "Removing Model Registry finalizer from InferenceService: $ISVC_NAME"

        # First try graceful deletion
        oc delete inferenceservice "$ISVC_NAME" -n "$LAB_PROJECT" --timeout=10s 2>/dev/null || true

        # If still exists, patch finalizers
        if oc get inferenceservice "$ISVC_NAME" -n "$LAB_PROJECT" &>/dev/null 2>&1; then
          warn "InferenceService $ISVC_NAME deletion timed out — patching finalizer"
          oc patch inferenceservice "$ISVC_NAME" -n "$LAB_PROJECT" --type=json \
            -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
          ok "Patched finalizer for $ISVC_NAME"
        fi
      fi
    done
  fi
else
  ok "Project $LAB_PROJECT not found — skipping InferenceService cleanup"
fi

# ── 2. Delete lab project ─────────────────────────────────────────────────────

if oc get project "$LAB_PROJECT" &>/dev/null; then
  info "Deleting project $LAB_PROJECT..."
  oc delete project "$LAB_PROJECT" --timeout=60s 2>/dev/null || {
    warn "Project deletion timed out — may still be terminating"
  }
  ok "Project $LAB_PROJECT deleted (or terminating)"
else
  ok "Project $LAB_PROJECT already gone"
fi

# ── 3. Delete Model Registry ──────────────────────────────────────────────────

info "Deleting model registry..."
oc delete -f "$SCRIPT_DIR/2-model-registry.yaml" --ignore-not-found --timeout=30s 2>/dev/null || {
  warn "Model registry deletion timed out"
}

# ── 4. Delete MySQL ───────────────────────────────────────────────────────────

info "Deleting MySQL..."
oc delete -f "$SCRIPT_DIR/1-mysql.yaml" --ignore-not-found --timeout=30s 2>/dev/null || {
  warn "MySQL deletion timed out"
}

# ── 5. Verify cleanup ─────────────────────────────────────────────────────────

if oc get project "$LAB_PROJECT" &>/dev/null 2>&1; then
  PHASE=$(oc get project "$LAB_PROJECT" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  if [[ "$PHASE" == "Terminating" ]]; then
    warn "Project $LAB_PROJECT is still terminating. Check with: oc get project $LAB_PROJECT"
  else
    warn "Project $LAB_PROJECT still exists with phase: $PHASE"
  fi
else
  ok "All resources cleaned up successfully"
fi

ok "Teardown complete."

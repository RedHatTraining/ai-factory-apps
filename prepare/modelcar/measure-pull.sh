#!/usr/bin/env bash
#
# measure-pull.sh — Measure the ModelCar OCI image PULL time for the exercise.
#
# Isolates the image-pull time (the part OCI caching actually affects) from the
# constant vLLM startup time, so the caching advantage is visible on a small
# model. It reads the kubelet's own pull events, not total pod-ready time.
#
#   cold   Force a genuine cold pull and report how long it took:
#            1. Scale the predictor Deployment to 0 (so the image is not in use).
#            2. Evict the model image from the GPU node's cache (crictl rmi).
#               This clears ONLY the node cache — the image stays in the internal
#               registry, so nothing has to be rebuilt or re-pushed.
#            3. Scale back to 1 and let the node pull the image from the registry.
#            4. Report the pull duration from the "Successfully pulled ... in Xs"
#               kubelet event.
#
#   warm   Delete the pod so it restarts with the image already cached, and
#          confirm the pull was skipped ("already present on machine" -> 0s).
#
# Run 'cold' first, then 'warm', to compare the two.
#
# This script MUTATES the cluster (scales the Deployment, deletes pods, and
# evicts the node image cache). It requires cluster-admin for the node eviction.
#
# Usage:
#   bash measure-pull.sh cold
#   bash measure-pull.sh warm
#
# Environment overrides (raise on slow lab environments):
#   OC_REQUEST_TIMEOUT   Per-call oc request cap            (default 30s)
#   READY_TIMEOUT        Wait for the pod to become Ready(s)(default 300)
#   DRAIN_TIMEOUT        Wait for the pod to terminate (s)  (default 120)
#
# Works on macOS and Linux (bash 3.2+). Uses no GNU-only tools.
#

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
info() { echo -e "  ${CYAN}→${NC} $*"; }
die()  { echo -e "\n${RED}${BOLD}✗ $*${NC}\n"; exit 1; }

# Cap each oc request so a slow/unreachable API fails fast instead of hanging.
# `oc wait` is exempt: it runs a long watch bounded by its own --timeout.
OC_REQUEST_TIMEOUT="${OC_REQUEST_TIMEOUT:-30s}"
oc() {
  if [[ "${1:-}" == "wait" ]]; then
    command oc "$@"
  else
    command oc --request-timeout="$OC_REQUEST_TIMEOUT" "$@"
  fi
}

# --- Exercise constants -------------------------------------------------------
NAMESPACE="prepare-modelcar"
ISVC="qwen3-modelcar"
SELECTOR="serving.kserve.io/inferenceservice=${ISVC}"
DEPLOYMENT="${ISVC}-predictor"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-120}"

# Set by resolve_image(): the model image reference and its repo (no tag).
IMAGE_REF=""
IMAGE_REPO=""

require_login() {
  oc whoami &>/dev/null || die "Not logged in to the cluster. Run: oc login -u <user> -p <password> <api-url>"
}

# resolve_image — read the model image from the InferenceService storageUri,
# stripping the oci:// scheme. Sets IMAGE_REF (with tag) and IMAGE_REPO (no tag).
resolve_image() {
  local uri
  uri=$(oc get inferenceservice "$ISVC" -n "$NAMESPACE" \
    -o jsonpath='{.spec.predictor.model.storageUri}' 2>/dev/null)
  [[ -n "$uri" ]] || die "InferenceService '$ISVC' not found in '$NAMESPACE'. Deploy it first."
  IMAGE_REF="${uri#oci://}"        # image-registry...:5000/ns/repo:tag
  IMAGE_REPO="${IMAGE_REF%:*}"     # image-registry...:5000/ns/repo   (drops :tag, keeps :5000)
}

# gpu_nodes — print the names of nodes that expose an NVIDIA GPU.
gpu_nodes() {
  oc get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.capacity.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
    | awk '$2 ~ /^[0-9]+$/ && $2 > 0 {print $1}'
}

# pod_name — print the model pod's name (empty if none matches the selector yet).
pod_name() {
  oc get pod -n "$NAMESPACE" -l "$SELECTOR" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

pod_count() {
  oc get pods -n "$NAMESPACE" -l "$SELECTOR" --no-headers 2>/dev/null | grep -c .
}

# dur_to_secs <go-duration> — convert e.g. 19.196s, 1m5.2s, 500ms to whole
# seconds (rounded). Go prints sub-second durations as "...ms".
dur_to_secs() {
  awk -v d="$1" 'BEGIN{
    if (d ~ /ms$/) { sub(/ms$/,"",d); printf "%.0f", d/1000; exit }
    s=0; rem=d;
    i=index(rem,"h"); if(i>0){ s+=substr(rem,1,i-1)*3600; rem=substr(rem,i+1) }
    i=index(rem,"m"); if(i>0){ s+=substr(rem,1,i-1)*60;   rem=substr(rem,i+1) }
    i=index(rem,"s"); if(i>0){ s+=substr(rem,1,i-1) }
    printf "%.0f", s
  }'
}

# pull_result <pod> — inspect the pod's kubelet events for the model image and
# echo one of:
#   "pulled <seconds>"   the node downloaded the image (cold pull)
#   "cached"             the image was already present (warm restart)
#   "unknown"            no pull event found (events aged out?)
pull_result() {
  local pod="$1" msgs line dur
  msgs=$(oc get events -n "$NAMESPACE" --field-selector involvedObject.name="$pod" \
    -o custom-columns=MSG:.message --no-headers 2>/dev/null | grep -F "$IMAGE_REPO")

  line=$(echo "$msgs" | grep "Successfully pulled" | head -1)
  if [[ -n "$line" ]]; then
    dur=$(echo "$line" | sed -E 's/.* in ([^ ]+) .*/\1/')
    echo "pulled $(dur_to_secs "$dur")"
    return 0
  fi
  if echo "$msgs" | grep -q "already present"; then
    echo "cached"
    return 0
  fi
  echo "unknown"
}

# show_evidence <pod> — print the raw kubelet pull event, so the reported number
# is verifiably the kubelet's own and not computed by this script.
show_evidence() {
  local pod="$1" line
  line=$(oc get events -n "$NAMESPACE" --field-selector involvedObject.name="$pod" \
    -o custom-columns=MSG:.message --no-headers 2>/dev/null \
    | grep -F "$IMAGE_REPO" | grep -E "Successfully pulled|already present" | head -1)
  [[ -n "$line" ]] && echo -e "  ${CYAN}kubelet event:${NC} ${line}"
}

# wait_ready — wait for the model pod to appear and become Ready.
wait_ready() {
  local i=0
  while [[ -z "$(pod_name)" ]]; do
    sleep 1; i=$(( i + 1 ))
    [[ "$i" -ge 30 ]] && die "No model pod appeared within 30s."
  done
  oc wait --for=condition=Ready pod -l "$SELECTOR" \
    -n "$NAMESPACE" --timeout="${READY_TIMEOUT}s" >/dev/null 2>&1 \
    || die "Pod did not become Ready within ${READY_TIMEOUT}s.
     Check: oc get pods -n ${NAMESPACE} -l ${SELECTOR}"
}

report() {
  local result="$1" kind="$2"   # kind: Cold | Warm
  case "$result" in
    pulled\ *)
      ok "${kind} image pull: ${result#pulled } seconds"
      [[ "$kind" == "Cold" ]] \
        && info "The node downloaded the model image from the registry." \
        || warn "The image was NOT cached — expected a warm restart to skip the pull."
      ;;
    cached)
      ok "${kind} image pull: 0 seconds (already present on machine)"
      [[ "$kind" == "Warm" ]] \
        && info "The node reused the cached image and skipped the download." \
        || warn "The image was still cached — this was NOT a genuine cold pull.
     The node eviction may have failed; re-run, or check cluster-admin access."
      ;;
    *)
      warn "${kind} pull time unknown — the kubelet pull event was not found (it may have aged out)."
      ;;
  esac
}

# --- cold: evict the node cache, force a pull, and time it ---------------------
measure_cold() {
  require_login
  resolve_image

  local nodes n evicted
  nodes=$(gpu_nodes)
  [[ -n "$nodes" ]] || die "No GPU nodes found — cannot evict the node image cache."

  info "Scaling '$DEPLOYMENT' to 0 to release the image..."
  oc scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=0 >/dev/null 2>&1 \
    || die "Failed to scale deployment '$DEPLOYMENT'."

  # Wait for the pod to terminate so the image is no longer in use by a container
  # (crictl rmi refuses to remove an image that a running container references).
  local i=0
  while [[ "$(pod_count)" != "0" ]]; do
    sleep 2; i=$(( i + 2 ))
    [[ "$i" -ge "$DRAIN_TIMEOUT" ]] && die "Pod did not terminate within ${DRAIN_TIMEOUT}s."
  done

  # Evict the model image (exact repo match, so the fallback image is left
  # alone). This removes it from the NODE only; the registry copy is untouched.
  # The remote helper reports EVICTED / NONE / INUSE so we can retry: right after
  # scale-down the pod's container may still be in its termination grace period,
  # during which crictl refuses to remove the in-use image.
  local remote="imgs=\$(crictl images 2>/dev/null | awk '\$1==\"${IMAGE_REPO}\"{print \$3}' | sort -u); \
if [ -z \"\$imgs\" ]; then echo NONE; \
elif crictl rmi \$imgs >/dev/null 2>&1; then echo EVICTED; \
else echo INUSE; fi"
  info "Evicting the model image from the GPU node cache (registry copy is kept)..."
  for n in $nodes; do
    local attempt=0 done_node=0
    while [[ "$attempt" -lt 30 ]]; do
      evicted=$(command oc debug node/"$n" --quiet -- \
                  chroot /host /bin/bash -c "$remote" 2>/dev/null)
      case "$evicted" in
        *EVICTED*) ok "Evicted model image from node '$n'"; done_node=1; break ;;
        *NONE*)    info "No model image cached on node '$n' (already clear)"; done_node=1; break ;;
        *)         sleep 2; attempt=$(( attempt + 1 )) ;;  # INUSE: container still terminating
      esac
    done
    [[ "$done_node" -eq 1 ]] || die "Model image on node '$n' stayed in use after 60s — could not evict.
     A pod may still be running. Check: oc get pods -n ${NAMESPACE}"
  done

  info "Scaling '$DEPLOYMENT' back to 1 to trigger a cold pull..."
  oc scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=1 >/dev/null 2>&1 \
    || die "Failed to scale deployment '$DEPLOYMENT' back to 1."

  info "Waiting for the pod to pull the image and become Ready (up to ${READY_TIMEOUT}s)..."
  wait_ready

  local pod; pod=$(pod_name)
  echo ""
  report "$(pull_result "$pod")" "Cold"
  show_evidence "$pod"
}

# --- warm: restart with the image cached and confirm the pull is skipped ------
measure_warm() {
  require_login
  resolve_image

  local pod
  pod=$(pod_name)
  [[ -n "$pod" ]] || die "No model pod found for '$ISVC'. Run 'measure-pull.sh cold' first."

  info "Deleting pod '$pod' to restart it (image already cached)..."
  oc delete pod "$pod" -n "$NAMESPACE" >/dev/null 2>&1 \
    || die "Failed to delete pod '$pod'."

  info "Waiting for the replacement pod to become Ready (up to ${READY_TIMEOUT}s)..."
  wait_ready

  local newpod; newpod=$(pod_name)
  echo ""
  report "$(pull_result "$newpod")" "Warm"
  show_evidence "$newpod"
}

case "${1:-}" in
  cold) measure_cold ;;
  warm) measure_warm ;;
  *)    die "Usage: bash measure-pull.sh cold | warm" ;;
esac

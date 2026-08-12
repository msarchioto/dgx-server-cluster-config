#!/usr/bin/env bash
# Request MIG split on one or more nodes by labeling nvidia.com/mig.config.
#
# Usage:
#   ./enable-mig.sh <strategy> <node> [node...]
#   ./enable-mig.sh --list
#   ./enable-mig.sh --status [node...]
#
# Examples:
#   ./enable-mig.sh h100-80gb-all-1g.10gb dgx-01
#   ./enable-mig.sh a100-80gb-balanced dgx-01 dgx-02
#   ./enable-mig.sh all-disabled dgx-01          # same as disable-mig.sh
#
# Prerequisites:
#   - GPU Operator installed with values-mig.yaml (migManager enabled)
#   - ConfigMap default-mig-parted-config applied in gpu-operator ns
#   - No non-MIG GPU pods running on the target node (drain recommended)
set -euo pipefail

CONFIGMAP_NS="${CONFIGMAP_NS:-gpu-operator}"
CONFIGMAP_NAME="${CONFIGMAP_NAME:-default-mig-parted-config}"
LABEL_KEY="nvidia.com/mig.config"
STATE_LABEL="nvidia.com/mig.config.state"

list_strategies() {
  if ! kubectl get configmap "${CONFIGMAP_NAME}" -n "${CONFIGMAP_NS}" &>/dev/null; then
    echo "ConfigMap ${CONFIGMAP_NS}/${CONFIGMAP_NAME} not found." >&2
    echo "Apply: kubectl apply -f manifests/mig-config.yaml" >&2
    exit 1
  fi
  echo "Available strategies in ${CONFIGMAP_NS}/${CONFIGMAP_NAME}:"
  kubectl get configmap "${CONFIGMAP_NAME}" -n "${CONFIGMAP_NS}" \
    -o jsonpath='{.data.config\.yaml}' \
    | sed -n 's/^[[:space:]]*\([a-zA-Z0-9._-]*\):[[:space:]]*$/  - \1/p' \
    | grep -v 'mig-configs' || true
}

show_status() {
  local nodes=("$@")
  if [[ ${#nodes[@]} -eq 0 ]]; then
    mapfile -t nodes < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  fi
  printf "%-20s %-32s %-16s %s\n" "NODE" "MIG_CONFIG" "MIG_STATE" "MIG_RESOURCES"
  for n in "${nodes[@]}"; do
    local cfg state
    cfg=$(kubectl get node "${n}" -o jsonpath="{.metadata.labels.${LABEL_KEY//./\\.}}" 2>/dev/null || true)
    cfg="${cfg:-<unset>}"
    state=$(kubectl get node "${n}" -o jsonpath="{.metadata.labels.nvidia\.com/mig\.config\.state}" 2>/dev/null || true)
    state="${state:-<unknown>}"
    # Collect allocatable mig* and gpu resources
    local res
    res=$(kubectl get node "${n}" -o json 2>/dev/null \
      | python3 -c '
import json,sys
d=json.load(sys.stdin)
alloc=d.get("status",{}).get("allocatable",{})
parts=[]
for k,v in sorted(alloc.items()):
    if k=="nvidia.com/gpu" or k.startswith("nvidia.com/mig-"):
        parts.append(f"{k}={v}")
print(",".join(parts) if parts else "-")
' 2>/dev/null || echo "-")
    printf "%-20s %-32s %-16s %s\n" "${n}" "${cfg}" "${state}" "${res}"
  done
}

if [[ $# -lt 1 ]]; then
  cat >&2 <<'EOF'
Usage:
  enable-mig.sh <strategy> <node> [node...]
  enable-mig.sh --list
  enable-mig.sh --status [node...]
EOF
  exit 1
fi

case "$1" in
  --list|-l)
    list_strategies
    exit 0
    ;;
  --status|-s)
    shift
    show_status "$@"
    exit 0
    ;;
esac

STRATEGY="$1"
shift
if [[ $# -lt 1 ]]; then
  echo "ERROR: provide at least one node name" >&2
  exit 1
fi

if ! kubectl get configmap "${CONFIGMAP_NAME}" -n "${CONFIGMAP_NS}" &>/dev/null; then
  echo "ERROR: ConfigMap ${CONFIGMAP_NS}/${CONFIGMAP_NAME} missing. Apply manifests/mig-config.yaml first." >&2
  exit 1
fi

# Soft-check strategy exists in config
if ! kubectl get configmap "${CONFIGMAP_NAME}" -n "${CONFIGMAP_NS}" \
    -o jsonpath='{.data.config\.yaml}' | grep -qE "^[[:space:]]*${STRATEGY}:[[:space:]]*$"; then
  echo "WARNING: strategy '${STRATEGY}' not found as a top-level key in ConfigMap (continuing anyway)." >&2
  echo "         Run: $0 --list" >&2
fi

for node in "$@"; do
  if ! kubectl get node "${node}" &>/dev/null; then
    echo "ERROR: node ${node} not found" >&2
    exit 1
  fi

  echo "==> Requesting MIG strategy '${STRATEGY}' on node ${node}"
  echo "    Tip: drain non-essential GPU pods first:"
  echo "      kubectl drain ${node} --ignore-daemonsets --delete-emptydir-data"

  kubectl label node "${node}" "${LABEL_KEY}=${STRATEGY}" --overwrite

  # Optional convenience labels for scheduling policies
  if [[ "${STRATEGY}" == "all-disabled" ]]; then
    kubectl label node "${node}" "nvidia.com/mig.capable-" "node-pool.mig-" --overwrite 2>/dev/null || true
    kubectl label node "${node}" "mig-mode=disabled" --overwrite
  else
    kubectl label node "${node}" "mig-mode=enabled" "node-pool.mig=${STRATEGY}" --overwrite
  fi

  echo "    Labeled. mig-manager will reconcile (often 1–3 minutes)."
done

echo ""
echo "Watch status:"
echo "  $0 --status $*"
echo "  kubectl logs -n ${CONFIGMAP_NS} -l app=nvidia-mig-manager -f"
echo ""
echo "When state is success, request slices in pods, e.g.:"
echo "  resources.limits['nvidia.com/mig-1g.10gb']: 1"
echo "See manifests/examples/ for sample pods."

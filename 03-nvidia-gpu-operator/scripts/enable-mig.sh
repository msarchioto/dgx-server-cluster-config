#!/usr/bin/env bash
# Request MIG split by labeling nvidia.com/mig.config.
# DRAINS the node by default (MIG reconfig terminates GPU clients).
#
# Usage:
#   ./enable-mig.sh <strategy> <node> [node...]
#   ./enable-mig.sh --list
#   ./enable-mig.sh --status [node...]
#   ./enable-mig.sh --no-drain <strategy> <node...>   # dangerous; for empty nodes only
#   ./enable-mig.sh --skip-uncordon <strategy> <node>
#
# Env: CONFIGMAP_NS=gpu-operator
set -euo pipefail

CONFIGMAP_NS="${CONFIGMAP_NS:-gpu-operator}"
CONFIGMAP_NAME="${CONFIGMAP_NAME:-default-mig-parted-config}"
LABEL_KEY="nvidia.com/mig.config"
DO_DRAIN=true
DO_UNCORDON=true

list_strategies() {
  echo "Preferred: use operator-generated profiles on each node (v26.3+):"
  echo "  kubectl get configmap -n ${CONFIGMAP_NS} -o name | grep mig-config || true"
  echo ""
  if kubectl get configmap "${CONFIGMAP_NAME}" -n "${CONFIGMAP_NS}" &>/dev/null; then
    echo "Strategies in ${CONFIGMAP_NS}/${CONFIGMAP_NAME}:"
    kubectl get configmap "${CONFIGMAP_NAME}" -n "${CONFIGMAP_NS}" \
      -o jsonpath='{.data.config\.yaml}' \
      | sed -n 's/^[[:space:]]*\([a-zA-Z0-9._-]*\):[[:space:]]*$/  - \1/p' \
      | grep -v 'mig-configs' || true
  else
    echo "Static ConfigMap ${CONFIGMAP_NAME} not found (OK if using generated configs)."
    echo "Common NVIDIA strategy names: all-disabled, all-1g.10gb, all-balanced, all-3g.40gb"
  fi
}

show_status() {
  local nodes=("$@")
  if [[ ${#nodes[@]} -eq 0 ]]; then
    mapfile -t nodes < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  fi
  printf "%-22s %-28s %-14s %s\n" "NODE" "MIG_CONFIG" "MIG_STATE" "NVIDIA_RESOURCES"
  for n in "${nodes[@]}"; do
    local cfg state res
    cfg=$(kubectl get node "${n}" -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config}' 2>/dev/null || true)
    cfg="${cfg:-<unset>}"
    state=$(kubectl get node "${n}" -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}' 2>/dev/null || true)
    state="${state:-<unknown>}"
    res=$(kubectl get node "${n}" -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
alloc=d.get("status",{}).get("allocatable",{})
parts=[f"{k}={v}" for k,v in sorted(alloc.items()) if k=="nvidia.com/gpu" or k.startswith("nvidia.com/mig-")]
print(",".join(parts) if parts else "-")
' 2>/dev/null || echo "-")
    printf "%-22s %-28s %-14s %s\n" "${n}" "${cfg}" "${state}" "${res}"
  done
}

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list|-l) list_strategies; exit 0 ;;
    --status|-s) shift; show_status "$@"; exit 0 ;;
    --no-drain) DO_DRAIN=false; shift ;;
    --skip-uncordon) DO_UNCORDON=false; shift ;;
    --help|-h)
      sed -n '2,14p' "$0" | tr -d '#'
      exit 0
      ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [[ ${#ARGS[@]} -lt 2 ]]; then
  echo "Usage: $0 [--no-drain] <strategy> <node> [node...]" >&2
  echo "       $0 --list | --status" >&2
  exit 1
fi

STRATEGY="${ARGS[0]}"
NODES=("${ARGS[@]:1}")

for node in "${NODES[@]}"; do
  if ! kubectl get node "${node}" &>/dev/null; then
    echo "ERROR: node ${node} not found" >&2
    exit 1
  fi

  echo "==> MIG strategy '${STRATEGY}' on ${node}"

  if [[ "${DO_DRAIN}" == "true" ]]; then
    echo "    Draining (required: mig-manager stops GPU clients)..."
    kubectl drain "${node}" \
      --ignore-daemonsets \
      --delete-emptydir-data \
      --force \
      --grace-period=60 \
      --timeout=600s || {
        echo "ERROR: drain failed. Fix pods or re-run with --no-drain only if node has no GPU user pods." >&2
        exit 1
      }
  else
    echo "    WARNING: --no-drain set; MIG apply may fail or kill running GPU pods."
  fi

  kubectl label node "${node}" "${LABEL_KEY}=${STRATEGY}" --overwrite

  if [[ "${STRATEGY}" == "all-disabled" ]]; then
    kubectl label node "${node}" mig-mode=disabled --overwrite
    kubectl label node "${node}" "node-pool.mig-" --overwrite 2>/dev/null || true
  else
    kubectl label node "${node}" mig-mode=enabled "node-pool.mig=${STRATEGY}" --overwrite
  fi

  echo "    Waiting for nvidia.com/mig.config.state=success (up to 10m)..."
  ok=false
  for _ in $(seq 1 60); do
    state=$(kubectl get node "${node}" -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}' 2>/dev/null || true)
    if [[ "${state}" == "success" ]]; then
      ok=true
      break
    fi
    if [[ "${state}" == "failed" ]]; then
      echo "ERROR: mig.config.state=failed on ${node}. Check: kubectl logs -n ${CONFIGMAP_NS} -l app=nvidia-mig-manager" >&2
      exit 1
    fi
    sleep 10
  done
  if [[ "${ok}" != "true" ]]; then
    echo "WARNING: timed out waiting for success (last state=${state:-unknown}). Check mig-manager logs." >&2
  else
    echo "    MIG config state: success"
  fi

  if [[ "${DO_DRAIN}" == "true" && "${DO_UNCORDON}" == "true" ]]; then
    echo "    Uncordoning ${node}"
    kubectl uncordon "${node}"
  fi
done

echo ""
show_status "${NODES[@]}"
echo ""
echo "Request slices in pods, e.g. limits: nvidia.com/mig-1g.10gb: 1"
echo "Examples: manifests/examples/"

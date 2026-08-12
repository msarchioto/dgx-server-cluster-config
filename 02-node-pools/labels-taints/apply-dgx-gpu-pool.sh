#!/usr/bin/env bash
# Label and (optionally) taint DGX worker nodes into the dgx-gpu pool.
# Usage: ./apply-dgx-gpu-pool.sh node1 [node2 ...]
# Env:
#   APPLY_TAINT=true|false   (default true)
#   GPU_PRODUCT=             optional override label value
set -euo pipefail

APPLY_TAINT="${APPLY_TAINT:-true}"
GPU_PRODUCT="${GPU_PRODUCT:-}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <node> [node...]" >&2
  exit 1
fi

for node in "$@"; do
  echo "==> Configuring node pool on ${node}"
  kubectl label node "${node}" \
    node-pool=dgx-gpu \
    workload=gpu \
    nvidia.com/gpu.present=true \
    --overwrite

  if [[ -n "${GPU_PRODUCT}" ]]; then
    kubectl label node "${node}" "nvidia.com/gpu.product=${GPU_PRODUCT}" --overwrite
  fi

  if [[ "${APPLY_TAINT}" == "true" ]]; then
    # Ignore error if taint already exists
    kubectl taint nodes "${node}" nvidia.com/gpu=true:NoSchedule --overwrite || true
  fi

  kubectl get node "${node}" --show-labels
done

echo "==> Done. Remember: GPU Operator may overwrite/augment nvidia.com/* labels."

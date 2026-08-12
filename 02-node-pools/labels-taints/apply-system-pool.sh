#!/usr/bin/env bash
# Label CPU / system nodes (ingress, monitoring, etc.).
# Usage: ./apply-system-pool.sh node1 [node2 ...]
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <node> [node...]" >&2
  exit 1
fi

for node in "$@"; do
  echo "==> Configuring system pool on ${node}"
  kubectl label node "${node}" \
    node-pool=system \
    workload=system \
    --overwrite
  kubectl get node "${node}" --show-labels
done

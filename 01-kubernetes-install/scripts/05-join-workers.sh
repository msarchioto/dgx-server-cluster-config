#!/usr/bin/env bash
# Join a worker (DGX) node to the cluster.
# Prefer a generated join command from the control plane.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATED_JOIN="${SCRIPT_DIR}/../generated/join-workers.sh"
JOIN_CONFIG="${SCRIPT_DIR}/../kubeadm/join-config.yaml"

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  echo "ERROR: this node already appears joined (kubelet.conf exists)." >&2
  exit 1
fi

if [[ $# -ge 1 ]]; then
  echo "==> Joining with provided arguments: $*"
  # shellcheck disable=SC2068
  kubeadm join $@
elif [[ -f "${GENERATED_JOIN}" ]]; then
  echo "==> Joining with ${GENERATED_JOIN}"
  bash "${GENERATED_JOIN}"
elif [[ -f "${JOIN_CONFIG}" ]]; then
  echo "==> Joining with config ${JOIN_CONFIG}"
  kubeadm join --config "${JOIN_CONFIG}"
else
  cat >&2 <<'EOF'
ERROR: no join method found.

Provide one of:
  1) Copy generated/join-workers.sh from the control plane to this path, or
  2) Fill kubeadm/join-config.yaml (from join-config.yaml.example), or
  3) Run: sudo bash 05-join-workers.sh <api-server:6443> --token <token> --discovery-token-ca-cert-hash sha256:<hash>
EOF
  exit 1
fi

echo "==> Worker join complete. On the control plane run: kubectl get nodes -o wide"

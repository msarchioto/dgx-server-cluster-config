#!/usr/bin/env bash
# Initialize the first Kubernetes control plane with kubeadm.
# Run as root on the first control-plane node only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/../kubeadm/init-config.yaml"
OUT_DIR="${SCRIPT_DIR}/../generated"
mkdir -p "${OUT_DIR}"

if [[ ! -f "${CONFIG}" ]]; then
  echo "ERROR: missing ${CONFIG}" >&2
  exit 1
fi

if [[ -f /etc/kubernetes/admin.conf ]]; then
  echo "ERROR: cluster appears already initialized (/etc/kubernetes/admin.conf exists)." >&2
  echo "       Use 'kubeadm reset' only if you intend to wipe this node." >&2
  exit 1
fi

echo "==> Preflight"
kubeadm config images pull --config "${CONFIG}"

echo "==> kubeadm init"
kubeadm init --config "${CONFIG}" --upload-certs | tee "${OUT_DIR}/kubeadm-init.log"

echo "==> Writing local kubeconfig for root (also copy for your user)"
export KUBECONFIG=/etc/kubernetes/admin.conf

echo "==> Generating worker join command"
kubeadm token create --print-join-command > "${OUT_DIR}/join-workers.sh"
chmod 600 "${OUT_DIR}/join-workers.sh"

echo "==> Control plane init complete"
echo ""
echo "Next steps:"
echo "  1. Configure kubectl for your user:"
echo "       mkdir -p \$HOME/.kube"
echo "       sudo cp /etc/kubernetes/admin.conf \$HOME/.kube/config"
echo "       sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config"
echo "  2. Install a CNI (from repo root or this host):"
echo "       kubectl apply -f 01-kubernetes-install/cni/calico.yaml"
echo "  3. Join workers using: ${OUT_DIR}/join-workers.sh"
echo "  4. Continue with 02-node-pools and 03-nvidia-gpu-operator"

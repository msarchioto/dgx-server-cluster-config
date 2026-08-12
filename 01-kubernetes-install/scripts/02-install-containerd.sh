#!/usr/bin/env bash
# Install and configure containerd for Kubernetes on Ubuntu/DGX.
# Run as root on every node.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_SRC="${REPO_ROOT}/01-kubernetes-install/container-runtime/containerd-config.toml"

export DEBIAN_FRONTEND=noninteractive

echo "==> Installing containerd"
apt-get update -y
apt-get install -y containerd

echo "==> Writing containerd config"
mkdir -p /etc/containerd
if [[ -f "${CONFIG_SRC}" ]]; then
  cp "${CONFIG_SRC}" /etc/containerd/config.toml
else
  containerd config default >/etc/containerd/config.toml
  # Ensure SystemdCgroup is enabled (required for kubelet + cgroup v2)
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
fi

systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd

echo "==> containerd status"
systemctl is-active containerd
containerd --version

echo "==> containerd install complete"
echo "    NVIDIA runtime will be configured by the GPU Operator (preferred),"
echo "    or manually if you use host NVIDIA Container Toolkit."

#!/usr/bin/env bash
# Install kubeadm, kubelet, kubectl (pinned version).
# Run as root on every node.
set -euo pipefail

# Pin versions for cluster homogeneity. Bump together when upgrading.
K8S_VERSION="${K8S_VERSION:-1.31}"
K8S_MINOR="${K8S_MINOR:-1.31.4}"  # apt package version prefix, e.g. 1.31.4-*

export DEBIAN_FRONTEND=noninteractive

echo "==> Adding Kubernetes apt repository (v${K8S_VERSION})"
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y \
  "kubelet=${K8S_MINOR}-*" \
  "kubeadm=${K8S_MINOR}-*" \
  "kubectl=${K8S_MINOR}-*"

apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

echo "==> Installed versions"
kubeadm version -o short
kubectl version --client -o yaml | head -n 20 || true

echo "==> kubeadm/kubelet/kubectl install complete"
echo "    Packages are apt-held. Unhold before upgrades: apt-mark unhold kubelet kubeadm kubectl"

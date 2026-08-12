#!/usr/bin/env bash
# Prepare Ubuntu bare-metal / DGX nodes for Kubernetes.
# Run on every node (control plane and workers) as root.
set -euo pipefail

echo "==> Disabling swap"
swapoff -a
sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab || true

echo "==> Loading kernel modules"
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo "==> Applying sysctl settings for Kubernetes networking"
cat >/etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.forwarding        = 1
# Helpful for high-throughput multi-GPU / multi-node training
net.core.rmem_max                   = 16777216
net.core.wmem_max                   = 16777216
net.ipv4.tcp_rmem                   = 4096 87380 16777216
net.ipv4.tcp_wmem                   = 4096 65536 16777216
EOF
sysctl --system

echo "==> Installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  software-properties-common \
  jq \
  nfs-common \
  open-iscsi \
  chrony

systemctl enable --now chrony || systemctl enable --now chronyd || true

echo "==> Node preparation complete"
echo "    Hostname: $(hostname -f 2>/dev/null || hostname)"
echo "    Kernel:   $(uname -r)"

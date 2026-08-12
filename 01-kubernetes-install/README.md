# Kubernetes Install on Bare-Metal DGX Nodes

This directory contains scripts and configs to bootstrap a production-ready
Kubernetes cluster on NVIDIA DGX servers (DGX A100, H100, H200, B200, etc.).

## Architecture assumptions

| Role | Count (example) | Notes |
|------|-----------------|-------|
| Control plane | 3 (HA) or 1 (lab) | Separate from GPU workers when possible |
| GPU workers (DGX) | 1–N | Full GPU + high-speed networking |
| Optional CPU pool | 0–N | Ingress, storage, system addons |

**Recommended for production:** 3 control-plane nodes + N DGX workers.

For multi-DGX **factory** lifecycle, NVIDIA **Base Command Manager (BCM)** is often
preferable to hand-rolled kubeadm; this directory documents the explicit DIY path.

## Prerequisites

- Ubuntu 22.04 LTS or 24.04 LTS (DGX OS / DGX Base OS preferred on GPU nodes)
- Root or passwordless sudo on all nodes
- Static IPs or reliable DHCP reservations
- Open ports between nodes (API 6443, etcd 2379–2380, kubelet 10250, NodePort range, CNI)
- NVIDIA drivers **not** pre-installed on GPU nodes if you use the GPU Operator (driver container).  
  Or use host drivers with `driver.enabled: false` in GPU Operator values.
- Clock sync (chrony/NTP)

## Install order

```text
1. prepare-nodes.sh          # kernel modules, sysctl, swap off, packages
2. install-containerd.sh     # containerd + NVIDIA runtime prep
3. install-kubeadm.sh        # kubeadm, kubelet, kubectl
4. init-control-plane.sh     # first control plane + CNI
5. join control planes       # optional HA
6. join-workers.sh           # DGX GPU workers
7. verify                    # nodes Ready, CNI healthy
```

Then continue with [02-node-pools](../02-node-pools/) and [03-nvidia-gpu-operator](../03-nvidia-gpu-operator/).

## Quick start (single control plane lab)

On **all** nodes:

```bash
sudo bash scripts/01-prepare-nodes.sh
sudo bash scripts/02-install-containerd.sh
sudo bash scripts/03-install-kubeadm.sh
```

On the **first control plane** only:

```bash
# Edit kubeadm/init-config.yaml: advertiseAddress, controlPlaneEndpoint, podSubnet
sudo bash scripts/04-init-control-plane.sh
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Install CNI (Calico example):

```bash
kubectl apply -f cni/calico.yaml
# or: helm install cilium cilium/cilium -n kube-system -f cni/cilium-values.yaml
```

On **worker / DGX** nodes:

```bash
# Copy join command from control plane (or use generated join-config)
sudo bash scripts/05-join-workers.sh
```

## Configuration files

| Path | Purpose |
|------|---------|
| `kubeadm/init-config.yaml` | kubeadm ClusterConfiguration + InitConfiguration |
| `kubeadm/join-config.yaml.example` | Worker join template |
| `container-runtime/containerd-config.toml` | containerd with SystemdCgroup |
| `cni/calico.yaml` | Calico CNI (VXLAN; adjust for BGP/RDMA fabrics) |
| `cni/cilium-values.yaml` | Cilium Helm values (optional) |

## DGX-specific notes

1. **Network**: Prefer a dedicated cluster/pod network separate from the management NIC. For multi-node NCCL, install Network Operator (`05-network-operator`) and validate with NCCL tests before training.
2. **Huge pages / CPU isolation**: Optional; see `kubelet-config-dgx-worker.yaml` for topology manager flags.
3. **Firewall**: Allow cluster ports; do not block GPU peer traffic on the fabric.
4. **SELinux/AppArmor**: DGX OS defaults usually work; test GPU Operator pods if you harden further.
5. **kubelet reserved resources**: Use larger reserves on DGX workers (`kubeadm/kubelet-config-dgx-worker.yaml`); control-plane defaults in `init-config.yaml` are smaller.
6. **DGX OS toolkit**: If Container Toolkit is preinstalled, use GPU Operator profile `dgx-os` (`toolkit.enabled=false`) and set host default runtime to `nvidia`.

## Verification

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl get cs   # legacy; prefer component status via pods in kube-system
```

All nodes should be `Ready`. GPU discovery comes after the GPU Operator is installed.

## HA control plane (optional)

1. Deploy an L4 load balancer or keepalived VIP for `controlPlaneEndpoint` (port 6443).
2. Set `controlPlaneEndpoint` in `init-config.yaml` before first `kubeadm init`.
3. After first control plane is up, run `kubeadm init phase upload-certs` and join additional control planes with `--control-plane`.

## Uninstall / reset

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /var/lib/etcd
# Reboot recommended after full reset
```

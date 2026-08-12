# dgx-server-cluster-config

Kubernetes configuration for an **NVIDIA DGX (or DGX-like) server cluster** on bare metal:
bootstrap, node pools, GPU Operator, networking, storage, scheduling, observability,
and PyTorch training/inference workers.

**Repository:** https://github.com/msarchioto/dgx-server-cluster-config

---

## Scope and non-goals

| This repo is | This repo is not |
|--------------|------------------|
| Explicit **kubeadm DIY** layout you can audit and fork | A replacement for **NVIDIA Base Command Manager (BCM)** |
| Lab → pilot path for single- and multi-node DGX | A full SuperPOD / multi-rack product distribution |
| Manifests + scripts for GPU Operator, MIG-on-request, NCCL checks | Managed cloud GPU (GKE/EKS/AKS) modules |

**When to use BCM instead:** multi-DGX production factories, provisioning at scale,
NVIDIA-supported lifecycle. BCM can install Kubernetes (kubeadm-based under the hood);
this repo teaches the pieces when you want full control or a custom OS image.

---

## Layout

```text
01-kubernetes-install/   # kubeadm bare-metal bootstrap
02-node-pools/           # labels, taints, RuntimeClass, priorities
03-nvidia-gpu-operator/  # Helm values + profiles (DGX OS / vanilla) + MIG
04-pytorch/              # workers, DDP, JobSet, NCCL validation
05-network-operator/     # multi-node RDMA / GPUDirect (optional)
06-storage/              # StorageClasses + PVC examples
07-scheduling/           # Kueue minimal queues
08-observability/        # Prometheus/Grafana + DCGM ServiceMonitor
docs/                    # architecture, checklist
```

---

## Recommended install order (production-minded)

```text
1. OS decision (DGX OS vs Ubuntu) + fabric firmware
2. Host drivers / OFED model (preinstalled vs Operator-managed) — pick ONE
3. containerd (+ host nvidia runtime if toolkit preinstalled)
4. kubeadm + CNI
5. Node labels/taints, PriorityClasses
6. GPU Operator (correct profile) + GPU smoke test
7. Network Operator (multi-node) + NCCL validation
8. Storage classes + PVCs
9. Observability (Prometheus + DCGM)
10. Kueue (training admission)
11. MIG only on designated inference nodes (optional)
12. Training / inference workers
```

Printable checklist: [docs/checklist.md](docs/checklist.md).

---

## Prerequisites

- DGX or GPU servers + control-plane machines
- Ubuntu 22.04/24.04 or **DGX OS**
- `kubectl`, `helm` 3 on admin workstation
- NGC image pull access (or registry mirror)

Pinned defaults (override with env):

| Component | Default pin |
|-----------|-------------|
| Kubernetes | v1.31.4 |
| GPU Operator chart | **v26.3.3** |
| Network Operator chart | v25.1.0 |
| NGC PyTorch | `nvcr.io/nvidia/pytorch:24.12-py3` |

---

## Phase guides

### 1 — Kubernetes (bare metal)

[01-kubernetes-install/README.md](01-kubernetes-install/README.md)

```bash
sudo bash 01-kubernetes-install/scripts/01-prepare-nodes.sh
sudo bash 01-kubernetes-install/scripts/02-install-containerd.sh
sudo bash 01-kubernetes-install/scripts/03-install-kubeadm.sh
# Edit kubeadm/init-config.yaml (CHANGE_ME)
sudo bash 01-kubernetes-install/scripts/04-init-control-plane.sh
bash 01-kubernetes-install/cni/install-calico.sh
# join workers…
```

DGX workers: larger kubelet reservations in  
`01-kubernetes-install/kubeadm/kubelet-config-dgx-worker.yaml`.

### 2 — Node pools

```bash
bash 02-node-pools/labels-taints/apply-dgx-gpu-pool.sh dgx-01 dgx-02
kubectl apply -f 02-node-pools/priority-classes.yaml
kubectl apply -f 02-node-pools/runtime-class/nvidia.yaml
```

Do **not** hand-set `nvidia.com/gpu.present` — GPU Feature Discovery owns it.

### 3 — GPU Operator

```bash
# DGX OS (preinstalled driver + toolkit) — recommended on DGX
bash 03-nvidia-gpu-operator/scripts/install-gpu-operator.sh dgx-os

# Vanilla Ubuntu (Operator installs driver + toolkit)
# bash 03-nvidia-gpu-operator/scripts/install-gpu-operator.sh vanilla

kubectl apply -f 02-node-pools/examples/gpu-pod-smoke-test.yaml
kubectl logs gpu-smoke-test && kubectl delete pod gpu-smoke-test
```

Profiles: `03-nvidia-gpu-operator/profiles/`. Chart pin: `GPU_OPERATOR_VERSION`.

### 4 — Multi-node fabric (if training across nodes)

```bash
bash 05-network-operator/scripts/install-network-operator.sh
# edit + apply 05-network-operator/manifests/nic-cluster-policy-example.yaml
kubectl apply -f 04-pytorch/validation/nccl-test-multinode.yaml
```

### 5 — Storage & observability & queues

```bash
# see 06-storage/README.md
# see 08-observability/README.md
# see 07-scheduling/kueue/README.md
```

### 6 — MIG (optional, split GPUs on request)

```bash
bash 03-nvidia-gpu-operator/scripts/install-gpu-operator-mig.sh dgx-os
bash 03-nvidia-gpu-operator/scripts/enable-mig.sh --list
# drains node by default
bash 03-nvidia-gpu-operator/scripts/enable-mig.sh all-1g.10gb dgx-01
```

Guide: [03-nvidia-gpu-operator/manifests/README-mig.md](03-nvidia-gpu-operator/manifests/README-mig.md).

### 7 — PyTorch workers

```bash
kubectl apply -f 04-pytorch/training/training-configmap.yaml
kubectl apply -f 04-pytorch/examples/example-scripts-configmap.yaml

# 1-GPU smoke training worker
kubectl apply -f 04-pytorch/workers/example-training-worker.yaml
kubectl logs -f job/example-training-worker

# Inference worker
kubectl apply -f 04-pytorch/workers/example-inference-worker.yaml

# Multi-node after NCCL OK: StatefulSet (preferred) or JobSet
kubectl apply -f 04-pytorch/training/multi-node-ddp-statefulset.yaml
# kubectl apply -f 04-pytorch/training/multi-node-jobset.yaml  # needs JobSet CRD

# Full 8-GPU node training
kubectl apply -f 04-pytorch/workers/overlays/full-node-training-patch.yaml
```

Indexed multi-node Job is **deprecated** (`multi-node-ddp-job.yaml` is a stub).

---

## Design notes

1. **DGX OS:** `driver.enabled=false` and `toolkit.enabled=false` (profile `dgx-os`).
2. **Smoke first:** examples default to **1 GPU**; full-node overlays are separate.
3. **NCCL before multi-node training.**
4. **MIG on request:** label `nvidia.com/mig.config=<strategy>`; manager drains GPU clients.
5. **Kueue** reduces partial multi-pod training deadlocks.
6. Prefer **BCM** for large multi-DGX lifecycle; this repo for transparent kubeadm control.

---

## Configuration placeholders

Search for `CHANGE_ME` before production (kubeadm endpoints, NFS server, Grafana password, etc.).

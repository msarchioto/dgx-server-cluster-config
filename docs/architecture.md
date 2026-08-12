# Architecture Overview

## Platform choice

```text
                    ┌─────────────────────────────┐
                    │  DIY kubeadm (this repo)    │
                    │  or NVIDIA BCM / OpenShift  │
                    └─────────────┬───────────────┘
                                  │
          ┌───────────────────────┼───────────────────────┐
          ▼                       ▼                       ▼
   control plane              system pool              DGX GPU pool
   (API/etcd)                 (ingress/mon)            (training/infer)
```

## Software stack

```text
OS (DGX OS | Ubuntu)
  → containerd (+ host nvidia runtime if preinstalled toolkit)
  → kubeadm + CNI
  → GPU Operator (device plugin, GFD, DCGM; driver/toolkit per profile)
  → Network Operator (multi-node RDMA)
  → Storage CSI / NFS / parallel FS
  → Prometheus + DCGM
  → Kueue (optional admission)
  → Workloads (PyTorch Job/StatefulSet/JobSet, inference Deployments)
```

## Multi-node training path

```text
GPU healthy → Network/RDMA → NCCL-tests → StatefulSet/JobSet DDP
```

Do not put NCCL solely on Calico VXLAN for production bandwidth expectations.

## MIG

Label-driven on-request partitions; default full GPU. Inference density ≠ training.

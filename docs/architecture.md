# Architecture Overview

## Logical layout

```text
                    ┌─────────────────────────────┐
                    │  API LB / VIP :6443         │
                    └─────────────┬───────────────┘
                                  │
          ┌───────────────────────┼───────────────────────┐
          │                       │                       │
   ┌──────▼──────┐         ┌──────▼──────┐         ┌──────▼──────┐
   │ control-0   │         │ control-1   │         │ control-2   │
   │ etcd+API    │         │ etcd+API    │         │ etcd+API    │
   └─────────────┘         └─────────────┘         └─────────────┘

   ┌─────────────────────────────────────────────────────────────┐
   │                     system pool (optional)                    │
   │  ingress · monitoring · registry · storage controllers        │
   └─────────────────────────────────────────────────────────────┘

   ┌──────────────┐  ┌──────────────┐       ┌──────────────┐
   │  DGX GPU-0   │  │  DGX GPU-1   │  ...  │  DGX GPU-N   │
   │  node-pool=  │  │              │       │              │
   │  dgx-gpu     │  │              │       │              │
   │  GPU Op DS   │  │              │       │              │
   │  training /  │  │              │       │              │
   │  inference   │  │              │       │              │
   └──────┬───────┘  └──────┬───────┘       └──────┬───────┘
          │                 │                      │
          └─────────────────┴──────────────────────┘
                    high-speed fabric (IB / RoCE)
                         NCCL multi-node
```

## Software stack (bottom → top)

1. **Ubuntu / DGX OS** on bare metal  
2. **containerd** + systemd cgroup driver  
3. **kubeadm Kubernetes** + CNI (Calico or Cilium)  
4. **Node pools** — labels, taints, PriorityClasses, RuntimeClass  
5. **NVIDIA GPU Operator** — toolkit, device plugin, DCGM, GFD  
6. **User workloads** — PyTorch DDP Jobs / inference Deployments  

## Networking model

| Traffic | Network | Notes |
|---------|---------|--------|
| Kubernetes API, kubelet | Management NIC | Control plane endpoint |
| Pod / Service CNI | Overlay or routed underlay | Calico VXLAN default in repo |
| Multi-node NCCL | IB / RoCE / high-BW Ethernet | Host network or carefully tuned CNI |

## Resource model

- GPUs exposed as extended resource: `nvidia.com/gpu`
- Optional MIG devices as separate resource names
- Scheduler places pods using requests/limits + nodeSelector + tolerations

## Security (baseline)

- Control-plane taints retained
- Optional GPU taint `nvidia.com/gpu=true:NoSchedule`
- Namespace ResourceQuotas for multi-tenant GPU caps
- Prefer private registry mirrors for NGC images

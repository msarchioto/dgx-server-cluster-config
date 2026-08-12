# PyTorch Distributed Training & Inference on DGX Kubernetes

This directory provides Kubernetes manifests for:

1. **Single-node multi-GPU** training (one DGX, all GPUs)
2. **Multi-node** distributed training (torchrun / DDP / NCCL across nodes)
3. **Online inference** (single or multi-GPU, optional multi-replica)
4. Shared storage patterns for datasets and checkpoints

## Design choices

| Topic | Recommendation |
|-------|----------------|
| Orchestration | Native Jobs / Deployments first; Kubeflow Training Operator optional |
| Process model | `torchrun` (elastic) with `NCCL` backend |
| GPU binding | `nvidia.com/gpu` limits + `runtimeClassName: nvidia` |
| Multi-node net | Prefer high-speed fabric; set NCCL IB/RoCE env; consider `hostNetwork` for NCCL |
| Storage | Read-only dataset PVC + read-write checkpoint PVC (RWX for multi-node) |
| Images | Official NGC PyTorch images (`nvcr.io/nvidia/pytorch`) |

## Prerequisites

- GPU Operator healthy; nodes advertise `nvidia.com/gpu`
- Node pool labels/taints from `02-node-pools`
- Container registry pull access to NGC (or mirrored images)
- For multi-node: pods can resolve each other; optional DNS headless service

## Directory layout

```text
04-pytorch/
├── training/
│   ├── single-node-ddp-job.yaml      # 1 node, N GPUs
│   ├── multi-node-ddp-job.yaml       # M nodes via torchrun rdzv
│   └── training-configmap.yaml       # shared NCCL / torch env
├── inference/
│   ├── inference-deployment.yaml    # serving Deployment + Service
│   └── inference-hpa-example.yaml   # optional HPA (CPU/custom)
├── storage/
│   ├── pvc-dataset.yaml
│   └── pvc-checkpoints.yaml
└── examples/
    ├── train_ddp_min.py             # minimal DDP script for smoke tests
    └── infer_http_min.py            # minimal HTTP inference stub
```

## Single-node multi-GPU (quick start)

```bash
kubectl apply -f storage/   # if using PVCs; else edit jobs to remove volumes
kubectl apply -f training/training-configmap.yaml
kubectl apply -f training/single-node-ddp-job.yaml
kubectl logs -f job/pytorch-ddp-single -c pytorch
```

## Multi-node training

1. Ensure nodes share fabric connectivity and NCCL env is correct.
2. Edit `multi-node-ddp-job.yaml`: `nnodes`, GPUs per node, image, command.
3. Apply ConfigMap + Job (or StatefulSet + headless Service pattern).

```bash
kubectl apply -f training/training-configmap.yaml
kubectl apply -f training/multi-node-ddp-job.yaml
kubectl get pods -l app=pytorch-ddp-multi -o wide
```

The multi-node example uses a **Job with a headless Service** and `torchrun`
rendezvous (`--rdzv_backend=c10d`). All worker pods share the same job and wait
on the rendezvous endpoint.

### NCCL checklist

```text
NCCL_DEBUG=INFO                 # start verbose, then WARN in prod
NCCL_IB_DISABLE=0               # 0 when IB/RoCE works
NCCL_SOCKET_IFNAME=eth0         # or ib0 / enp* — must match data NIC
NCCL_IB_HCA=mlx5_0              # optional pin
NCCL_NET_GDR_LEVEL=PHB          # optional tune
```

If NCCL hangs on multi-node, test with `hostNetwork: true` to rule out CNI MTU/issues.

## Inference

```bash
kubectl apply -f inference/inference-deployment.yaml
kubectl get svc pytorch-inference
# Port-forward for lab:
kubectl port-forward svc/pytorch-inference 8080:8080
```

Scale replicas carefully: each replica requests GPUs. For multi-tenant density,
enable MIG or time-slicing in the GPU Operator.

## Using Kubeflow Training Operator (optional)

If you install [Training Operator](https://www.kubeflow.org/docs/components/training/),
you can convert Jobs to `PyTorchJob` CRDs for cleaner rank/world-size wiring.
Native Jobs in this repo avoid that dependency for bare-metal bootstrap.

## Resource guidelines (starting points)

| Workload | GPUs | CPU (request) | Memory (request) |
|----------|------|---------------|------------------|
| Smoke DDP | 1–2 | 4–8 | 16–64Gi |
| Full DGX node | 8 | 32–64 | 256Gi–1Ti |
| Multi-node 2×DGX | 16 | per-node as above | per-node as above |
| Inference replica | 1 | 4–16 | 16–64Gi |

Always set **limits == requests** for GPUs. For CPU/memory, prefer Guaranteed QoS
on production training by matching requests and limits.

## Security notes

- Do not run training as root in production; NGC images often default to root—override
  `securityContext.runAsUser` when possible.
- Use imagePullSecrets for private registries.
- Mount datasets read-only; restrict checkpoint PVC access via RBAC.

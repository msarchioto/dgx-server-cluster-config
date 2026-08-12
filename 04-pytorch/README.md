# PyTorch on DGX Kubernetes

## Defaults

Examples use **1 GPU** so first runs schedule on any healthy GPU node.
Full-node (8 GPU) overlays live under `workers/overlays/`.

## Order

1. GPU smoke test  
2. Single-node training worker  
3. (Multi-node) Network Operator + **NCCL validation** (`validation/`)  
4. Multi-node StatefulSet or JobSet  
5. Inference workers / MIG inference  

## Workers

```bash
kubectl apply -f training/training-configmap.yaml
kubectl apply -f examples/example-scripts-configmap.yaml
kubectl apply -f workers/example-training-worker.yaml
kubectl apply -f workers/example-inference-worker.yaml
```

See [workers/README.md](workers/README.md).

## Multi-node

| Manifest | Master / rdzv (node rank 0) | Notes |
|----------|----------------------------|--------|
| `training/multi-node-ddp-job.yaml` | `JOB_COMPLETION_INDEX=0` + DNS `pytorch-ddp-multi-0.<svc>` | Indexed Job; hostname set by Job controller |
| `training/multi-node-ddp-statefulset.yaml` | Ordinal `0` via hostname | Stable pod identity |
| `training/multi-node-jobset.yaml` | JobSet completion index `0` | Needs JobSet CRD |

```bash
kubectl apply -f validation/nccl-test-multinode.yaml   # first
kubectl apply -f training/training-configmap.yaml
kubectl apply -f examples/example-scripts-configmap.yaml
kubectl apply -f training/multi-node-ddp-job.yaml
# or: training/multi-node-ddp-statefulset.yaml
```

## Kueue

Optional admission: [../07-scheduling/kueue](../07-scheduling/kueue).

## Storage

Point PVCs at classes from [../06-storage](../06-storage).

# Example Workers

Ready-to-apply **training** and **inference** worker configurations for the DGX
GPU pool. These are the primary templates to copy when adding real workloads.

| Manifest | Kind | Role | Default GPUs |
|----------|------|------|--------------|
| [`example-training-worker.yaml`](example-training-worker.yaml) | Job + ConfigMap + SA | Batch multi-GPU training (1 node) | 8 |
| [`example-inference-worker.yaml`](example-inference-worker.yaml) | Deployment + Service + PDB + ConfigMap + SA | Online GPU serving | 1 per replica |

Both workers:

- Use `runtimeClassName: nvidia`
- Select `node-pool=dgx-gpu` and tolerate `nvidia.com/gpu=true:NoSchedule`
- Use PriorityClasses from `02-node-pools`
- Mount the smoke-test scripts ConfigMap (swap for your code/image)

## Prerequisites

```bash
# Cluster must already have GPU Operator + node pool setup
kubectl apply -f ../../02-node-pools/priority-classes.yaml
kubectl apply -f ../../02-node-pools/runtime-class/nvidia.yaml
kubectl apply -f ../training/training-configmap.yaml      # NCCL env (training)
kubectl apply -f ../examples/example-scripts-configmap.yaml
```

## Training worker

```bash
# Optional: reduce GPUs for a quick smoke (edit nvidia.com/gpu + NPROC_PER_NODE first)
kubectl apply -f example-training-worker.yaml

kubectl get job,pod -l worker-role=training -o wide
kubectl logs -f job/example-training-worker -c training-worker

# Cleanup
kubectl delete -f example-training-worker.yaml
```

**What it does:** runs `torchrun --standalone` with `train_ddp_min.py` (NCCL
all-reduce smoke). Replace the command with your training entrypoint and enable
dataset/checkpoint PVC mounts in the manifest.

**Key knobs (ConfigMap `example-training-worker-config`):**

| Key | Purpose |
|-----|---------|
| `NPROC_PER_NODE` | Processes per node (= GPUs typically) |
| `DATA_DIR` / `CHECKPOINT_DIR` | Paths once PVCs are mounted |
| `TRAIN_*` | Example hyperparams for your script |

For **multi-node** training workers, use
[`../training/multi-node-ddp-statefulset.yaml`](../training/multi-node-ddp-statefulset.yaml)
instead of this single-node Job.

## Inference worker

```bash
kubectl apply -f example-inference-worker.yaml

kubectl get deploy,pod,svc -l worker-role=inference -o wide
kubectl port-forward svc/example-inference-worker 8080:8080
curl -s localhost:8080/healthz | jq .
curl -s localhost:8080/v1/info | jq .
curl -s -X POST localhost:8080/v1/predict | jq .

# Scale out (each replica requests 1 GPU)
kubectl scale deploy/example-inference-worker --replicas=2

# Cleanup
kubectl delete -f example-inference-worker.yaml
```

**What it does:** runs the minimal HTTP server (`infer_http_min.py`) with
startup/readiness/liveness probes, a ClusterIP Service, and a PodDisruptionBudget.

**Key knobs (ConfigMap `example-inference-worker-config`):**

| Key | Purpose |
|-----|---------|
| `PORT` | HTTP listen port (Service targets 8080) |
| `MODEL_DEVICE` | e.g. `cuda:0` |
| `MODEL_PATH` / `MODEL_NAME` | For a real model server |
| `MAX_BATCH_SIZE` | Application batching hint |

Replace the container command with TorchServe, Triton, vLLM, or your own server
and mount model weights (PVC or image layer).

## Labels

| Label | Training | Inference |
|-------|----------|-----------|
| `worker-role` | `training` | `inference` |
| `workload` | `training` | `inference` |
| `app` | `example-training-worker` | `example-inference-worker` |

Use these for network policies, monitoring selectors, and cost allocation.

## Resource profile cheat sheet

| Worker | CPU req/lim | Memory req/lim | GPU |
|--------|-------------|----------------|-----|
| Training (full DGX) | 32 / 64 | 256Gi / 512Gi | 8 |
| Inference (1 GPU) | 4 / 16 | 16Gi / 64Gi | 1 |

Edit resources for your DGX SKU (H100 8-GPU, etc.) and multi-tenant packing
(MIG / time-slicing via GPU Operator).

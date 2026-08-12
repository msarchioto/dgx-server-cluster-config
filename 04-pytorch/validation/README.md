# Fabric & multi-node validation (before training)

Run these **after** GPU Operator (and Network Operator if multi-node RDMA).

## Order

1. Single-node GPU smoke (`02-node-pools/examples/gpu-pod-smoke-test.yaml`)
2. Single-node DDP smoke (`workers/example-training-worker.yaml` — 1 GPU default)
3. **NCCL multi-node test** (this directory)
4. Only then: multi-node training (StatefulSet / JobSet)

## NCCL multi-node

```bash
# Edit nnodes / GPU count / nodeSelector as needed
kubectl apply -f nccl-test-multinode.yaml
kubectl logs -f statefulset/nccl-test -c nccl
kubectl delete -f nccl-test-multinode.yaml
```

Expect all-reduce bandwidth in the same order of magnitude as your fabric
(not single-digit GB/s on InfiniBand if the fabric is healthy).

# NVIDIA Network Operator (multi-node RDMA / GPUDirect)

For **multi-node** DGX training, the pod network (Calico/Cilium) is not enough.
NCCL needs a high-speed fabric (InfiniBand or RoCE) and usually:

- Host OFED / NVIDIA networking drivers (or Network Operator managed)
- RDMA device plugin resources
- Optional secondary network (Macvlan/SR-IOV) for pod RDMA

## When to install

| Workload | Network Operator |
|----------|------------------|
| Single-node multi-GPU | Optional |
| Multi-node DDP / NCCL | **Recommended** |
| Inference only (single node) | Skip |

**Install order:** Kubernetes Ready → GPU Operator healthy → **this** → NCCL-tests → PyTorch multi-node.

## Install

```bash
# Review values for your NICs / secondary network mode
./scripts/install-network-operator.sh

# Or manually:
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm upgrade --install network-operator nvidia/network-operator \
  -n network-operator --create-namespace \
  --version "${NETWORK_OPERATOR_VERSION:-v25.1.0}" \
  -f values/values.yaml
```

Then apply a **NicClusterPolicy** (example in `manifests/`) matching your fabric.

## Validation

```bash
kubectl apply -f ../04-pytorch/validation/nccl-test-multinode.yaml
# see 04-pytorch/validation/README.md
```

## References

- https://docs.nvidia.com/networking/display/kubernetes2570/deployment-guide-kubernetes.html
- https://github.com/Mellanox/network-operator

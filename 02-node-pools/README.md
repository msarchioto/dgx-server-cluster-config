# Node Pool Configuration

Node pools group machines by role so the scheduler places workloads correctly
and system pods do not steal GPU capacity from training jobs.

## Recommended pools

| Pool | Node type | Labels (key examples) | Taints | Typical workloads |
|------|-----------|------------------------|--------|-------------------|
| `control-plane` | CPU / small | `node-pool=control-plane` | control-plane NoSchedule | API, etcd, controllers |
| `system` | CPU | `node-pool=system` | optional | ingress, monitoring, registry |
| `dgx-gpu` | DGX (A100/H100/…) | `node-pool=dgx-gpu`, `nvidia.com/gpu.product=…` | `nvidia.com/gpu=true:NoSchedule` (optional) | training, inference |
| `dgx-inference` | DGX slice | `node-pool=dgx-inference` | optional softer taints | online serving |

GPU Operator will add detailed NVIDIA labels (`nvidia.com/gpu.count`,
`nvidia.com/gpu.memory`, MIG profiles, etc.) after install.

## Apply order

1. Label and taint nodes (after they join and are `Ready`).
2. Apply RuntimeClasses for NVIDIA (`nvidia`, optional MIG classes).
3. Apply PriorityClasses for training vs batch vs system.
4. Use nodeSelectors / affinity / tolerations in job templates (see `04-pytorch`).

## Quick apply

```bash
# Edit node names in scripts or pass as args
./labels-taints/apply-dgx-gpu-pool.sh dgx-01 dgx-02
kubectl apply -f runtime-class/
kubectl apply -f priority-classes.yaml
kubectl apply -f resource-quotas-example.yaml   # optional, per namespace
```

## Labeling strategy

### Required for this repo’s examples

```text
node-pool=dgx-gpu|system|control-plane
workload=gpu|system
nvidia.com/gpu.present=true          # on GPU nodes (also set by GPU Operator)
```

### Helpful for multi-SKU clusters

```text
nvidia.com/gpu.product=NVIDIA-H100-80GB-HBM3
node.kubernetes.io/instance-type=dgx-h100
topology.kubernetes.io/zone=dc1-rack-a
feature.node.kubernetes.io/pci-10de.present=true
```

### Multi-node training topology

For NCCL multi-node jobs, keep nodes in the same high-bandwidth domain:

```text
network.topology.dgx/domain=ib-fabric-1
network.topology.dgx/rail=rail-0
```

Use pod affinity on `network.topology.dgx/domain` so ranks land on the same fabric.

## Taints

Optional GPU taint (recommended when system pods would otherwise schedule freely):

```bash
kubectl taint nodes dgx-01 nvidia.com/gpu=true:NoSchedule
```

Workloads then need:

```yaml
tolerations:
  - key: nvidia.com/gpu
    operator: Equal
    value: "true"
    effect: NoSchedule
```

Control-plane taints are set by kubeadm; do not remove them unless you intentionally
allow workloads on control plane (lab only).

## Capacity and packing

- Prefer **whole-node** jobs for multi-GPU training (8 GPUs on a classic DGX).
- Use **MIG** or time-slicing (GPU Operator) for multi-tenant inference.
- Set `nvidia.com/gpu` resource requests equal to GPUs needed; never oversubscribe
  unless using time-slicing config intentionally.

## Verification

```bash
kubectl get nodes --show-labels
kubectl describe node <dgx-node> | sed -n '/Labels:/,/Taints:/p'
kubectl describe node <dgx-node> | sed -n '/Allocated resources:/,/Events:/p'
kubectl get runtimeclass
```

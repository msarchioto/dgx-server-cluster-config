# MIG: split GPUs on request

Nodes stay on **full GPUs** (`all-disabled`) until you label a strategy.
`enable-mig.sh` **drains** the node by default (mig-manager stops GPU clients).

## Install

```bash
./scripts/install-gpu-operator-mig.sh dgx-os
```

## Strategies

Prefer **auto-generated** ConfigMaps per node (GPU Operator v26.3+):

```bash
kubectl get configmap -n gpu-operator | grep mig-config
```

Static optional strategies (aligned with NVIDIA docs):

| Name | Typical use |
|------|-------------|
| `all-disabled` | Full GPUs |
| `all-1g.10gb` | 7 small slices (H100/A100-80 class) |
| `all-3g.40gb` | 2 medium slices |
| `all-balanced` | Mix of 1g/2g/3g |
| `all-1g.5gb` | A100-40 class |

Always confirm: `nvidia-smi mig -lgip`.

## Request / restore

```bash
./scripts/enable-mig.sh --list
./scripts/enable-mig.sh all-1g.10gb dgx-01
./scripts/enable-mig.sh --status dgx-01
./scripts/disable-mig.sh dgx-01
```

Pods (mixed strategy):

```yaml
resources:
  limits:
    nvidia.com/mig-1g.10gb: 1
```

Examples: `manifests/examples/`.

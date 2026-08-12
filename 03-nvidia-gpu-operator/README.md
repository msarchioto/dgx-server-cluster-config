# NVIDIA GPU Operator

The GPU Operator installs and manages the NVIDIA software stack on Kubernetes:

- NVIDIA driver (optional containerized driver)
- Container toolkit (configures containerd for `nvidia` runtime)
- Device plugin (`nvidia.com/gpu` resources)
- DCGM / DCGM Exporter (metrics)
- GPU Feature Discovery (node labels)
- Optional: MIG Manager, MFA, Validator, Node Feature Discovery

## When to use host drivers vs operator drivers

| Mode | Use when | values.yaml setting |
|------|----------|---------------------|
| **Operator driver** | Vanilla Ubuntu workers without DGX OS drivers | `driver.enabled: true` |
| **Host driver** | DGX OS / preinstalled drivers (recommended on DGX) | `driver.enabled: false` |

DGX systems usually ship with a validated driver + CUDA stack. Prefer **host drivers**
on DGX OS and let the Operator manage toolkit, device plugin, and monitoring.

## Install

```bash
# Prerequisites: Helm 3, cluster Ready, nodes labeled if using node selectors
./scripts/install-gpu-operator.sh

# Or manually:
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update
kubectl create namespace gpu-operator --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install gpu-operator nvidia/gpu-operator \
  -n gpu-operator \
  -f values.yaml \
  --wait
```

## Upgrade

```bash
helm repo update
helm upgrade gpu-operator nvidia/gpu-operator -n gpu-operator -f values.yaml --wait
```

## Multi-node networking (NCCL / RDMA)

For multi-node distributed training:

1. Install Mellanox/NVIDIA networking drivers and OFED on the host (or use network
   operator where applicable).
2. Enable RDMA device plugin / secondary network as needed (see `manifests/`).
3. Set NCCL env vars in training jobs (see `04-pytorch`).

`values.yaml` includes commented options for `rdma` and GFD.

## MIG and time-slicing

### MIG — split GPUs on request (recommended path)

Full guide: [manifests/README-mig.md](manifests/README-mig.md)

Nodes keep **full GPUs by default**. You split only the nodes you label.

```bash
# MIG-capable install (or upgrade existing operator)
./scripts/install-gpu-operator-mig.sh

# List strategies / apply a split / restore full GPUs
./scripts/enable-mig.sh --list
./scripts/enable-mig.sh h100-80gb-all-1g.10gb dgx-01
./scripts/enable-mig.sh --status dgx-01
./scripts/disable-mig.sh dgx-01

# Workload that requests a slice
kubectl apply -f manifests/examples/mig-slice-smoke-test.yaml
```

| File | Purpose |
|------|---------|
| `manifests/mig-config.yaml` | Named layouts (A100/H100, balanced, all-disabled) |
| `values-mig.yaml` | Helm overlay: `migManager` + `mig.strategy=mixed` |
| `scripts/enable-mig.sh` | Label nodes to request a strategy |
| `scripts/disable-mig.sh` | Back to full GPUs (`all-disabled`) |
| `manifests/examples/mig-*.yaml` | Smoke test + inference on slices |

Pods request profile resources after a split, e.g. `nvidia.com/mig-1g.10gb: 1`.

### Time-slicing

- Soft-share a full GPU across pods (no MIG-level isolation). See `manifests/time-slicing-config.yaml`.

**Do not** enable MIG and time-slicing on the same GPUs.

## Verification

```bash
kubectl get pods -n gpu-operator
kubectl get nodes -o json | jq -r '.items[] | select(.status.allocatable["nvidia.com/gpu"]!=null) | "\(.metadata.name) gpus=\(.status.allocatable["nvidia.com/gpu"])"'
kubectl apply -f ../02-node-pools/examples/gpu-pod-smoke-test.yaml
kubectl logs gpu-smoke-test
kubectl delete pod gpu-smoke-test
```

Expected: `vectorAdd` sample completes with `Test PASSED`.

## Troubleshooting

| Symptom | Checks |
|---------|--------|
| No `nvidia.com/gpu` on nodes | Device plugin pods; driver loaded (`nvidia-smi` on host if host drivers) |
| Pods stuck ContainerCreating | Toolkit not patched containerd; RuntimeClass handler |
| CrashLoop nvidia-driver-daemonset | Prefer host drivers on DGX OS; check secure boot / nouveau blacklist |
| NCCL multi-node hangs | Fabric, IPs, NCCL_IB_*, firewall, hostNetwork |

## Uninstall

```bash
helm uninstall gpu-operator -n gpu-operator
kubectl delete ns gpu-operator
# Nodes may retain nvidia runtime config in containerd; reboot or clean if reinstalling cleanly
```

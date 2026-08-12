# MIG: split GPUs on request

**MIG (Multi-Instance GPU)** partitions a physical GPU (A100, H100, …) into
isolated instances with dedicated memory and compute. This repo is set up so
nodes stay on **full GPUs by default** and only **split when you request it**
via a node label.

## When to use MIG

| Use case | Prefer |
|----------|--------|
| Multi-tenant **inference**, many small models | MIG slices |
| **Training** that needs full bandwidth / NVLink | Full GPU (`all-disabled`) |
| Soft sharing without isolation | Time-slicing (different feature) |

Do **not** enable MIG and time-slicing on the same GPUs.

## Architecture (on-request flow)

```text
1. Install GPU Operator + values-mig.yaml
   └─ migManager watching nodes; default strategy = all-disabled

2. You request a split on a node:
   kubectl label node dgx-01 nvidia.com/mig.config=h100-80gb-all-1g.10gb

3. nvidia-mig-manager reconfigures GPUs on that node

4. Device plugin advertises slice resources (mixed strategy), e.g.:
   nvidia.com/mig-1g.10gb: "56"   # 8 GPUs × 7 slices

5. Pods request slices:
   resources.limits["nvidia.com/mig-1g.10gb"]: 1

6. Restore full GPUs:
   kubectl label node dgx-01 nvidia.com/mig.config=all-disabled
```

## Install (MIG-capable operator)

```bash
cd 03-nvidia-gpu-operator
bash scripts/install-gpu-operator-mig.sh
# equivalent:
#   kubectl apply -f manifests/mig-config.yaml
#   helm upgrade --install gpu-operator nvidia/gpu-operator \
#     -n gpu-operator -f values.yaml -f values-mig.yaml --wait
```

If the operator is already installed without MIG:

```bash
kubectl apply -f manifests/mig-config.yaml
helm upgrade gpu-operator nvidia/gpu-operator \
  -n gpu-operator -f values.yaml -f values-mig.yaml --wait
```

## Request a split

```bash
# List strategy names from the ConfigMap
./scripts/enable-mig.sh --list

# Drain GPU workloads on the node (recommended)
kubectl drain dgx-01 --ignore-daemonsets --delete-emptydir-data

# Request partition layout
./scripts/enable-mig.sh h100-80gb-all-1g.10gb dgx-01
# or: a100-80gb-balanced, a100-40gb-all-1g.5gb, …

# Wait until state is success
./scripts/enable-mig.sh --status dgx-01
kubectl get node dgx-01 -o json | jq '.status.allocatable | with_entries(select(.key|startswith("nvidia.com")))'

kubectl uncordon dgx-01
```

## Run a MIG workload

```bash
# Edit resource name in the manifest if your profile differs
kubectl apply -f manifests/examples/mig-slice-smoke-test.yaml
kubectl logs mig-slice-smoke-test
kubectl delete pod mig-slice-smoke-test

# Multi-replica inference on slices
kubectl apply -f ../../04-pytorch/examples/example-scripts-configmap.yaml
kubectl apply -f manifests/examples/mig-inference-worker.yaml
```

Pod resource snippet:

```yaml
resources:
  limits:
    nvidia.com/mig-1g.10gb: 1   # profile from your strategy
```

With **mixed** strategy (`values-mig.yaml`), you request the **profile resource**.
Full GPUs remain `nvidia.com/gpu` on nodes that are still `all-disabled`.

## Disable MIG (full GPUs again)

```bash
kubectl drain dgx-01 --ignore-daemonsets --delete-emptydir-data
./scripts/disable-mig.sh dgx-01
# wait for success, then:
kubectl uncordon dgx-01
```

## Strategies shipped in `mig-config.yaml`

| Strategy | Typical hardware | Result (per GPU) |
|----------|------------------|------------------|
| `all-disabled` | any | No MIG; full `nvidia.com/gpu` |
| `a100-40gb-all-1g.5gb` | A100 40GB | 7× 1g.5gb |
| `a100-80gb-all-1g.10gb` | A100 80GB | 7× 1g.10gb |
| `a100-80gb-balanced` | A100 80GB | mix 1g/2g/3g |
| `h100-80gb-all-1g.10gb` | H100 80GB | 7× 1g.10gb |
| `h100-80gb-all-3g.40gb` | H100 80GB | 2× 3g.40gb |
| `h100-80gb-balanced` | H100 80GB | mix |

**Always validate** on hardware:

```bash
nvidia-smi -L
nvidia-smi mig -lgip
```

Edit `manifests/mig-config.yaml` if your SKU reports different profile names.

## Labels used by this repo

| Label | Set by | Purpose |
|-------|--------|---------|
| `nvidia.com/mig.config=<strategy>` | `enable-mig.sh` | mig-manager desired config |
| `nvidia.com/mig.config.state` | mig-manager | success / failed / pending |
| `mig-mode=enabled\|disabled` | `enable-mig.sh` | scheduling selector for MIG pods |
| `node-pool.mig=<strategy>` | `enable-mig.sh` | optional pin to a layout |

## Troubleshooting

| Symptom | Action |
|---------|--------|
| `mig.config.state=failed` | Check `kubectl logs -n gpu-operator -l app=nvidia-mig-manager`; wrong profile for SKU |
| Pod Pending on `mig-*` resource | Node not split yet, or wrong profile name in pod |
| Cannot apply MIG | Drain pods still holding full GPUs; reboot rarely needed |
| Training NCCL across MIG slices | Prefer full GPUs; MIG slices are weaker for multi-GPU training |

## Related files

| Path | Role |
|------|------|
| `manifests/mig-config.yaml` | Named partition strategies |
| `values-mig.yaml` | Helm overlay (`mig.strategy=mixed`, manager on) |
| `scripts/enable-mig.sh` / `disable-mig.sh` | On-request split / restore |
| `scripts/install-gpu-operator-mig.sh` | One-shot MIG-ready install |
| `manifests/examples/*` | Smoke test + inference on slices |

# NVIDIA GPU Operator

Pinned chart default: **`v26.3.3`** (`GPU_OPERATOR_VERSION`).

## Profiles (pick one)

| Profile | File | When |
|---------|------|------|
| **dgx-os** | `profiles/values-dgx-os.yaml` | DGX OS / Base OS: host driver **and** toolkit already installed |
| **vanilla** | `profiles/values-vanilla-ubuntu.yaml` | Ubuntu without NVIDIA stack: Operator installs both |

```bash
# Namespace gets privileged PSA automatically
./scripts/install-gpu-operator.sh dgx-os
./scripts/install-gpu-operator.sh vanilla
```

### DGX OS host prep

Before Operator with `toolkit.enabled=false`, set the **default runtime to nvidia**
(see [NVIDIA Container Toolkit configuration](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)).

## MIG on request

```bash
./scripts/install-gpu-operator-mig.sh dgx-os
./scripts/enable-mig.sh all-1g.10gb dgx-01   # drains by default
./scripts/disable-mig.sh dgx-01
```

Prefer hardware-generated profiles (Operator v26.3+). Custom strategies in
`manifests/mig-config.yaml` use NVIDIA-aligned names (`all-1g.10gb`, `all-balanced`, …).

Full guide: [manifests/README-mig.md](manifests/README-mig.md).

## Verification

```bash
kubectl get clusterpolicy
kubectl get pods -n gpu-operator
kubectl apply -f ../02-node-pools/examples/gpu-pod-smoke-test.yaml
```

## Time-slicing

See `manifests/time-slicing-config.yaml`. Do not combine with MIG on the same GPUs.

## CDI

Base `values.yaml` enables CDI. Workloads in this repo still set
`runtimeClassName: nvidia` for explicitness.

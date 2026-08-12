# dgx-server-cluster-config

Kubernetes configuration for an **NVIDIA DGX server cluster** on bare metal:
cluster bootstrap, node pools, GPU Operator, and PyTorch distributed
training/inference.

Upload this repository to GitHub when ready; nothing here requires a remote
to apply manifests locally.

```text
dgx-server-cluster-config/
├── 01-kubernetes-install/   # kubeadm bare-metal bootstrap
├── 02-node-pools/           # labels, taints, RuntimeClass, priorities
├── 03-nvidia-gpu-operator/  # Helm values + install script
├── 04-pytorch/              # DDP training + inference examples
├── docs/                    # architecture & checklist
└── README.md                # this guide
```

---

## What you get

| Area | Contents |
|------|----------|
| **1. Kubernetes on bare metal** | Node prep scripts, containerd, kubeadm init/join configs, Calico/Cilium |
| **2. Node pools** | DGX GPU vs system labels/taints, PriorityClasses, RuntimeClass, quotas |
| **3. NVIDIA GPU Operator** | Helm `values.yaml` tuned for DGX (host drivers by default), MIG/time-slice samples |
| **4. PyTorch distributed** | Single-node DDP Job, multi-node StatefulSet/Job, inference Deployment, NCCL env |
| **5. Docs** | End-to-end guide (below), [architecture](docs/architecture.md), [checklist](docs/checklist.md) |

---

## Prerequisites

- One or more **DGX** (or GPU) servers + control-plane machines (can be DGX or CPU)
- **Ubuntu 22.04/24.04** or **DGX OS**
- SSH + sudo on all nodes
- Workstation with `kubectl` and `helm` (Helm needed for GPU Operator)
- Network plan: management CIDR, optional IB/RoCE fabric, non-overlapping pod CIDR

Pinned defaults in this repo (override as needed):

- Kubernetes **v1.31.x**
- Calico **v3.28.x** (or Cilium values provided)
- NGC PyTorch image **`nvcr.io/nvidia/pytorch:24.12-py3`**

---

## End-to-end configuration guide

### Phase 1 — Install Kubernetes on bare metal

Details: [01-kubernetes-install/README.md](01-kubernetes-install/README.md)

**On every node:**

```bash
cd 01-kubernetes-install
sudo bash scripts/01-prepare-nodes.sh
sudo bash scripts/02-install-containerd.sh
sudo bash scripts/03-install-kubeadm.sh
```

**Edit before first control plane:**

- `kubeadm/init-config.yaml` — replace every `CHANGE_ME`
  - `advertiseAddress`, `controlPlaneEndpoint`, node name, cert SANs
  - Confirm `podSubnet` (`192.168.0.0/16` matches Calico CR in this repo)

**First control plane:**

```bash
sudo bash scripts/04-init-control-plane.sh
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown "$(id -u):$(id -g)" $HOME/.kube/config
```

**CNI (Calico example):**

```bash
bash cni/install-calico.sh
# or: helm install cilium … -f cni/cilium-values.yaml
```

**Workers (DGX):**

```bash
# Copy generated/join-workers.sh from control plane, then:
sudo bash scripts/05-join-workers.sh
```

**Verify:**

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

All nodes should be `Ready` before continuing.

---

### Phase 2 — Node pool configuration

Details: [02-node-pools/README.md](02-node-pools/README.md)

```bash
# Label (and taint) DGX workers
bash 02-node-pools/labels-taints/apply-dgx-gpu-pool.sh dgx-01 dgx-02

# Optional CPU/system nodes
bash 02-node-pools/labels-taints/apply-system-pool.sh sys-01

kubectl apply -f 02-node-pools/priority-classes.yaml
kubectl apply -f 02-node-pools/runtime-class/nvidia.yaml
```

| Label | Meaning |
|-------|---------|
| `node-pool=dgx-gpu` | Schedulable GPU capacity for training/inference |
| `workload=gpu` | Workload class selector |
| `nvidia.com/gpu=true:NoSchedule` taint | Only GPU-tolerant pods land on DGX |

GPU Operator will add richer `nvidia.com/*` labels once installed.

---

### Phase 3 — NVIDIA GPU Operator

Details: [03-nvidia-gpu-operator/README.md](03-nvidia-gpu-operator/README.md)

1. Review `03-nvidia-gpu-operator/values.yaml`
   - **DGX OS / existing drivers:** keep `driver.enabled: false` (default)
   - **Vanilla Ubuntu without drivers:** set `driver.enabled: true`
2. Install:

```bash
bash 03-nvidia-gpu-operator/scripts/install-gpu-operator.sh
```

3. Wait until nodes advertise GPUs:

```bash
kubectl get pods -n gpu-operator
kubectl get node -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu
```

4. Smoke test:

```bash
kubectl apply -f 02-node-pools/examples/gpu-pod-smoke-test.yaml
kubectl logs gpu-smoke-test
kubectl delete pod gpu-smoke-test
```

Optional: MIG / time-slicing manifests under `03-nvidia-gpu-operator/manifests/`.

---

### Phase 4 — PyTorch distributed training & inference

Details: [04-pytorch/README.md](04-pytorch/README.md)

**Apply shared config and example scripts:**

```bash
kubectl apply -f 04-pytorch/training/training-configmap.yaml
kubectl apply -f 04-pytorch/examples/example-scripts-configmap.yaml
```

**Tune NCCL** in `pytorch-distributed-env` ConfigMap:

- `NCCL_SOCKET_IFNAME` — data-plane interface (`eth0`, `ib0`, `ens…`)
- `NCCL_IB_DISABLE=0` when InfiniBand/RoCE is available

**Single-node multi-GPU (one full DGX):**

```bash
# Edit GPU count / resources if not 8-GPU
kubectl apply -f 04-pytorch/training/single-node-ddp-job.yaml
kubectl logs -f job/pytorch-ddp-single
```

**Multi-node (recommended: StatefulSet for stable DNS):**

```bash
# Edit replicas / NNODES / nproc_per_node to match fleet
kubectl apply -f 04-pytorch/training/multi-node-ddp-statefulset.yaml
kubectl logs -f statefulset/pytorch-ddp-sts -c pytorch
# Tear down when finished:
# kubectl delete -f 04-pytorch/training/multi-node-ddp-statefulset.yaml
```

An Indexed **Job** variant also exists: `training/multi-node-ddp-job.yaml`.

**Inference:**

```bash
kubectl apply -f 04-pytorch/inference/inference-deployment.yaml
kubectl port-forward svc/pytorch-inference 8080:8080
curl -s localhost:8080/healthz
curl -s -X POST localhost:8080/v1/predict
```

Storage PVC templates: `04-pytorch/storage/` (set `storageClassName` for your platform).

---

## Suggested apply order (summary)

```text
01 prepare + containerd + kubeadm
02 kubeadm init → CNI → join workers
03 node labels / taints / PriorityClass / RuntimeClass
04 GPU Operator Helm install → GPU smoke test
05 PyTorch ConfigMaps → DDP job → inference Deployment
```

Printable checklist: [docs/checklist.md](docs/checklist.md).

---

## Configuration reference (placeholders)

Search the repo for `CHANGE_ME` and replace before production use:

| Location | Values to set |
|----------|----------------|
| `01-kubernetes-install/kubeadm/init-config.yaml` | IPs, endpoint, hostnames, cert SANs |
| `01-kubernetes-install/cni/cilium-values.yaml` | `k8sServiceHost` |
| `04-pytorch/**` | GPU counts, image tags, PVC storage classes |
| `03-nvidia-gpu-operator/values.yaml` | `driver.enabled`, optional nodeSelector |

---

## Design notes for DGX

1. **Drivers:** Prefer host drivers on DGX OS; let the Operator manage toolkit + device plugin.
2. **Whole-node training:** Request all GPUs on a node (`nvidia.com/gpu: 8` on classic 8-GPU DGX) and use anti-affinity for multi-node ranks.
3. **NCCL:** Validate multi-node with the smoke `train_ddp_min.py` before large jobs; use `NCCL_DEBUG=INFO` while debugging.
4. **Isolation:** GPU taints + namespace ResourceQuotas keep system and tenant workloads separated.
5. **Sharing:** MIG or time-slicing for inference density — enable deliberately per pool, not cluster-wide by accident.

---

## Upload to GitHub (later)

```bash
cd dgx-server-cluster-config
git remote add origin git@github.com:<org>/dgx-server-cluster-config.git
git push -u origin main
```

Or create the empty repo in the GitHub UI / `gh repo create`, then push.

---

## License

Configuration and scripts in this repository are provided as-is for operators of
private DGX clusters. NVIDIA, DGX, CUDA, and NGC are trademarks of NVIDIA
Corporation. Review NVIDIA software licenses for drivers, GPU Operator, and NGC images.

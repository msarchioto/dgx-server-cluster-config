# Storage for datasets and checkpoints

Training needs **fast read** for datasets and **shared write** for multi-node checkpoints.

## Options in this repo

| Path | Use |
|------|-----|
| `storageclasses/local-path.yaml` | Lab: node-local disk via rancher local-path provisioner |
| `storageclasses/nfs.yaml` | Shared NFS RWX (edit server/path) |
| `examples/pvc-*.yaml` | PVC samples bound to those classes |

## Recommended mapping

| Data | Access | Class |
|------|--------|--------|
| Datasets | ROX / RWX | NFS, Lustre, WEKA, JuiceFS, … |
| Checkpoints (multi-node) | **RWX** | NFS / parallel FS |
| Checkpoints (single-node) | RWO | local-path or block CSI |
| Model weights (inference) | ROX | NFS or image layers |

DGX production often uses **parallel filesystems** (Lustre, GPFS, WEKA) not shipped here—point `storageClassName` at your CSI.

## Quick lab setup (local-path)

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
kubectl apply -f storageclasses/local-path.yaml
kubectl apply -f examples/pvc-dataset-local.yaml
kubectl apply -f examples/pvc-checkpoints-local.yaml
```

## NFS

```bash
# Edit server/export in storageclasses/nfs.yaml first
kubectl apply -f storageclasses/nfs.yaml
kubectl apply -f examples/pvc-dataset-nfs.yaml
```

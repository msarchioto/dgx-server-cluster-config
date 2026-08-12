# Example workers

| Manifest | Default GPUs | Role |
|----------|--------------|------|
| `example-training-worker.yaml` | **1** | Training Job smoke |
| `example-inference-worker.yaml` | **1** | Inference Deployment |
| `overlays/full-node-training-patch.yaml` | **8** | Full DGX node training |

```bash
kubectl apply -f ../training/training-configmap.yaml
kubectl apply -f ../examples/example-scripts-configmap.yaml
kubectl apply -f example-training-worker.yaml
kubectl apply -f example-inference-worker.yaml
```

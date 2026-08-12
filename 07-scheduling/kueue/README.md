# Kueue (minimal) — training job admission

[Kueue](https://kueue.sigs.k8s.io/) admits Jobs when resources are available and
supports **all-or-nothing** style multi-pod training better than bare scheduler.

## Install

```bash
# Pin version; check latest releases
KUEUE_VERSION="${KUEUE_VERSION:-v0.10.1}"
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/kueue/releases/download/${KUEUE_VERSION}/manifests.yaml"

# ClusterQueue + LocalQueue + ResourceFlavor for GPU nodes
kubectl apply -f resource-flavor-dgx.yaml
kubectl apply -f cluster-queue.yaml
kubectl apply -f local-queue-default.yaml
```

## Use with a Job

Label the Job (or namespace default queue) so Kueue manages it:

```yaml
metadata:
  labels:
    kueue.x-k8s.io/queue-name: dgx-training
```

Example: `example-training-job-kueue.yaml`

## Why

Without a queue, multi-node training can schedule 1 of 2 workers and deadlock
waiting for GPUs. Kueue holds the Job until the whole request can fit (with
appropriate configuration / JobSet integration).

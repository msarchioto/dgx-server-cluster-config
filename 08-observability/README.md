# Observability (DCGM + Prometheus + Grafana)

GPU Operator can expose **DCGM Exporter** metrics. Wire them into Prometheus
via `ServiceMonitor` when [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
or Prometheus Operator is installed.

## Enable

1. GPU Operator `values.yaml` already sets `dcgmExporter.serviceMonitor.enabled: true`.
2. Install Prometheus stack (if not present):

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f kube-prometheus-stack-values.yaml
```

3. Apply extra ServiceMonitors if needed:

```bash
kubectl apply -f servicemonitors/dcgm-exporter.yaml
```

4. Grafana: import NVIDIA DCGM dashboard (community ID often **12239** or
   NVIDIA’s published JSON). Datasource = Prometheus.

## Quick checks

```bash
kubectl get pods -n gpu-operator -l app=nvidia-dcgm-exporter
kubectl get servicemonitor -A | grep -i dcgm || true
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
```

## Alerts (starter)

See `docs/alert-ideas.md` for high GPU temperature, XID errors, and stuck jobs.

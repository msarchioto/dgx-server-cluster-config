# Starter GPU alert ideas

| Alert | Signal | Why |
|-------|--------|-----|
| GPU XID errors | DCGM `DCGM_FI_DEV_XID_ERRORS` | Hardware/driver faults |
| High temp | `DCGM_FI_DEV_GPU_TEMP` | Cooling / oversubscribe |
| High util stuck | util ~100% for hours + no progress logs | hung train |
| MIG apply failed | `nvidia.com/mig.config.state=failed` | bad profile |
| Node NotReady | kube node condition | fabric/power |

Implement as PrometheusRule objects once metrics are flowing.

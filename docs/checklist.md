# Deployment Checklist

## Pre-flight

- [ ] Inventory DGX hostnames, management IPs, fabric IPs
- [ ] Confirm Ubuntu/DGX OS version and kernel
- [ ] Decide: host NVIDIA drivers vs GPU Operator drivers
- [ ] Reserve pod CIDR and service CIDR (no overlap with LAN)
- [ ] API endpoint DNS or VIP planned
- [ ] NTP/chrony working on all nodes
- [ ] Firewall rules allow cluster + fabric traffic

## Kubernetes install

- [ ] `01-prepare-nodes.sh` on all nodes
- [ ] `02-install-containerd.sh` on all nodes
- [ ] `03-install-kubeadm.sh` on all nodes (same version)
- [ ] `init-config.yaml` filled (`CHANGE_ME` resolved)
- [ ] Control plane initialized
- [ ] CNI installed; all nodes `Ready`
- [ ] Workers joined
- [ ] `kubectl get nodes -o wide` looks correct

## Node pools

- [ ] DGX nodes labeled `node-pool=dgx-gpu`
- [ ] Optional GPU taint applied
- [ ] PriorityClasses applied
- [ ] RuntimeClass `nvidia` applied (or created by Operator)

## GPU Operator

- [ ] Helm values reviewed (`driver.enabled` correct for OS)
- [ ] Operator installed; pods healthy in `gpu-operator`
- [ ] Nodes show `nvidia.com/gpu` allocatable
- [ ] Smoke pod `gpu-smoke-test` passes

## PyTorch

- [ ] Example scripts ConfigMap applied
- [ ] Distributed env ConfigMap tuned (`NCCL_SOCKET_IFNAME`)
- [ ] Example training worker Job succeeds (`workers/example-training-worker.yaml`)
- [ ] Example inference worker healthy; `/healthz` OK (`workers/example-inference-worker.yaml`)
- [ ] Single-node DDP job succeeds (optional alternate)
- [ ] Multi-node StatefulSet (or Job) succeeds all-reduce
- [ ] Dataset / checkpoint storage classes decided

## Production hardening (follow-on)

- [ ] etcd backups
- [ ] Monitoring (Prometheus + DCGM dashboards)
- [ ] Log aggregation
- [ ] Image registry mirror / pull secrets
- [ ] NetworkPolicies as needed
- [ ] Upgrade runbook for Kubernetes + GPU Operator

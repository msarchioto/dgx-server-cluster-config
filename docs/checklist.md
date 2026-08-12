# Deployment Checklist

## Scope

- [ ] Chose **kubeadm DIY** (this repo) vs **BCM** for multi-DGX lifecycle

## Pre-flight

- [ ] Hostnames, mgmt IPs, fabric IPs inventoried
- [ ] DGX OS vs Ubuntu decided → GPU Operator **profile** chosen
- [ ] Pod/service CIDR non-overlapping
- [ ] API VIP/DNS planned
- [ ] NTP OK; NGC pull path OK

## Kubernetes

- [ ] prepare / containerd / kubeadm on all nodes
- [ ] `init-config.yaml` CHANGE_ME filled
- [ ] CNI up; all nodes Ready
- [ ] DGX workers use larger kubelet reserves (reference file applied)

## Node pools

- [ ] `node-pool=dgx-gpu` (no manual `gpu.present`)
- [ ] GPU taint if desired
- [ ] PriorityClasses + RuntimeClass

## GPU Operator

- [ ] Privileged PSA on `gpu-operator` ns
- [ ] Chart pin (v26.3.3+) + profile (dgx-os / vanilla)
- [ ] ClusterPolicy ready; GPUs allocatable
- [ ] `gpu-smoke-test` PASSED

## Multi-node fabric

- [ ] Network Operator / OFED path decided
- [ ] NicClusterPolicy applied if needed
- [ ] NCCL multi-node validation OK bandwidth

## Storage / observability / queues

- [ ] StorageClass (local-path or NFS/parallel FS)
- [ ] Prometheus + DCGM ServiceMonitor
- [ ] Kueue ClusterQueue quotas match fleet

## MIG (optional)

- [ ] MIG overlay installed
- [ ] `enable-mig.sh` drain success → slice smoke
- [ ] `disable-mig.sh` restores full GPUs when needed

## Workloads

- [ ] Training worker 1-GPU smoke OK
- [ ] Inference worker `/healthz` OK
- [ ] Multi-node StatefulSet/JobSet only after NCCL OK
- [ ] Full-node overlay only when intentional

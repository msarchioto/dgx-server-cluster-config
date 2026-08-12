#!/usr/bin/env python3
"""Minimal multi-GPU / multi-node DDP smoke test for DGX Kubernetes jobs.

Exercises torch.distributed + NCCL without a heavy model. Safe to run as a
cluster validation step after GPU Operator install.
"""
from __future__ import annotations

import os
import time

import torch
import torch.distributed as dist


def main() -> None:
    backend = "nccl" if torch.cuda.is_available() else "gloo"
    dist.init_process_group(backend=backend)

    rank = dist.get_rank()
    world = dist.get_world_size()
    local_rank = int(os.environ.get("LOCAL_RANK", 0))

    if torch.cuda.is_available():
        torch.cuda.set_device(local_rank)
        device = torch.device("cuda", local_rank)
        dev_name = torch.cuda.get_device_name(local_rank)
    else:
        device = torch.device("cpu")
        dev_name = "cpu"

    print(
        f"[rank {rank}/{world}] local_rank={local_rank} device={device} ({dev_name})",
        flush=True,
    )

    # All-reduce a small tensor to validate collective connectivity.
    tensor = torch.ones(1, device=device) * (rank + 1)
    dist.all_reduce(tensor, op=dist.ReduceOp.SUM)
    expected = float(world * (world + 1) / 2)
    got = float(tensor.item())

    if abs(got - expected) > 1e-3:
        raise RuntimeError(f"all_reduce mismatch: got {got}, expected {expected}")

    # Tiny compute to touch GEMM paths on GPU.
    if device.type == "cuda":
        a = torch.randn(1024, 1024, device=device)
        b = torch.randn(1024, 1024, device=device)
        for _ in range(20):
            a = a @ b
        torch.cuda.synchronize(device)

    dist.barrier()
    if rank == 0:
        print(f"DDP smoke OK: world_size={world} all_reduce_sum={got}", flush=True)
        time.sleep(1)

    dist.destroy_process_group()


if __name__ == "__main__":
    main()

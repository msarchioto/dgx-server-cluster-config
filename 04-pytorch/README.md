# PyTorch on DGX Kubernetes

## Defaults

Examples use **1 GPU** so first runs schedule on any healthy GPU node.
Full-node (8 GPU) overlays live under `workers/overlays/`.

## Order

1. GPU smoke test  
2. Single-node training worker  
3. (Multi-node) Network Operator + **NCCL validation** (`validation/`)  
4. Multi-node StatefulSet or JobSet  
5. Inference workers / MIG inference  

## Workers

```bash
kubectl apply -f training/training-configmap.yaml
kubectl apply -f examples/example-scripts-configmap.yaml
kubectl apply -f workers/example-training-worker.yaml
kubectl apply -f workers/example-inference-worker.yaml
```

See [workers/README.md](workers/README.md).

## Multi-node

Rendezvous store host is always Kubernetes index **0** (not an election).
How that differs from `RANK=0`, and how `NNODES` / `JOB_COMPLETION_INDEX`
become torchrun flags: [How torchrun actually runs a job](#how-torchrun-actually-runs-a-job).

| Manifest | Store host (rdzv endpoint) | Notes |
|----------|----------------------------|--------|
| `training/multi-node-ddp-job.yaml` | `JOB_COMPLETION_INDEX=0` + DNS `pytorch-ddp-multi-0.<svc>` | Indexed Job; hostname set by Job controller |
| `training/multi-node-ddp-statefulset.yaml` | Ordinal `0` via hostname | Stable pod identity |
| `training/multi-node-jobset.yaml` | JobSet completion index `0` | Needs JobSet CRD |

```bash
kubectl apply -f validation/nccl-test-multinode.yaml   # first
kubectl apply -f training/training-configmap.yaml
kubectl apply -f examples/example-scripts-configmap.yaml
kubectl apply -f training/multi-node-ddp-job.yaml
# or: training/multi-node-ddp-statefulset.yaml
```

## Kueue

Optional admission: [../07-scheduling/kueue](../07-scheduling/kueue).

## Storage

Point PVCs at classes from [../06-storage](../06-storage).

## How torchrun actually runs a job

Flags are listed later. This section is the runtime: which values the pod
computes, how rendezvous forms a worker group, and who becomes “master”.

There is **no leader election**. Two different hosts get called “master” and
they are chosen in two different ways:

| Role | Who it is | How it is chosen |
|------|-----------|------------------|
| **Rendezvous store host** | The process that binds `--rdzv_endpoint` and serves the c10d `TCPStore` | **You pick it.** This repo always points the endpoint at Kubernetes index **0**. |
| **Process-group master** (`RANK=0`, `MASTER_ADDR`) | The worker `dist.init_process_group` treats as rank 0 | **Assigned after the barrier.** c10d sorts participating nodes and gives `GROUP_RANK=0` to the first. That node’s local worker 0 is global `RANK=0`. |

`--node_rank` does **not** elect either of them when `--rdzv_backend=c10d`
(this repo). It is only consumed by `--rdzv_backend=static`.

### 1 — Dynamic parameters the pod fills in

Before `torchrun` starts, the container script turns Kubernetes identity into
CLI flags. Nothing here is elected; it is either a ConfigMap value or a
controller-injected index.

| Variable | Where it comes from | Becomes |
|----------|---------------------|---------|
| `NNODES` | Job env (`2` on multi-node examples, `1` on smoke) | `--nnodes` |
| `NPROC_PER_NODE` | Job env (`1` smoke, `8` full-node overlay) | `--nproc_per_node` |
| `NODE_RANK` | Indexed Job / JobSet: `JOB_COMPLETION_INDEX`. StatefulSet: last label of `HOSTNAME` (`pytorch-ddp-sts-0` → `0`) | `--node_rank` (ignored under c10d; kept so a static-backend switch still works) |
| `RDZV_HOST` | Hard-coded to the **index-0** headless DNS name | left half of `--rdzv_endpoint` |
| `RDZV_PORT` | `29500` | right half of `--rdzv_endpoint` |
| `--rdzv_id` | Constant per manifest (`pytorch-ddp-multi`, …) | job membership key |
| `--rdzv_backend` | Constant `c10d` | store implementation |

**How Kubernetes makes index 0 addressable**

1. `completionMode: Indexed` (or a StatefulSet ordinal) gives every pod a
   stable integer `0 … nnodes-1` and hostname `<name>-<index>`.
2. A **headless** Service (`clusterIP: None`) plus `spec.subdomain` (Job) or
   `serviceName` (StatefulSet) publishes
   `<hostname>.<svc>.<ns>.svc.cluster.local`.
3. `publishNotReadyAddresses: true` is required: pod 0 must resolve **before**
   it is Ready, otherwise the other agents cannot open the store and
   rendezvous times out.
4. Pod anti-affinity on `kubernetes.io/hostname` puts one replica per node.

So for the Indexed Job, every replica runs the same image and the same
command. The only thing that differs is `JOB_COMPLETION_INDEX`. Index 0’s
DNS name is known *a priori* — that is why `--rdzv_endpoint` can be a
constant.

```text
pod pytorch-ddp-multi-0   JOB_COMPLETION_INDEX=0   hostname=pytorch-ddp-multi-0
pod pytorch-ddp-multi-1   JOB_COMPLETION_INDEX=1   hostname=pytorch-ddp-multi-1
                          │
                          ▼
--rdzv_endpoint=pytorch-ddp-multi-0.pytorch-ddp-multi:29500   (both pods)
--nnodes=2  --nproc_per_node=1  --rdzv_id=pytorch-ddp-multi
```

Single-node jobs skip all of this: `--standalone` forges a private c10d store
on `localhost:<ephemeral-port>` with a random `--rdzv_id`. That one process
is store host and rank 0.

**`PET_*` overrides.** Most flags also read `PET_<DEST>` when the CLI value
is omitted (`PET_NNODES`, `PET_NPROC_PER_NODE`, `PET_RDZV_BACKEND`, …).
These manifests pass the flags explicitly, so `PET_*` is unused unless you
drop a flag.

### 2 — What rendezvous is

Rendezvous is a **barrier + peer discovery + shared key-value store**. Every
node’s `torchrun` agent (not the training script) joins it. Workers are
spawned only after it completes.

It guarantees:

- **Barrier.** Nobody starts until at least `min` nodes have joined the
  same `--rdzv_id`. If `max` arrive, the barrier closes immediately. If only
  `min` have arrived (`min < max`), it waits `last_call_timeout` (default
  30s) for stragglers, then closes.
- **Exclusivity.** A second group cannot form under the same `--rdzv_id`
  while the first is still running. Late nodes go on a wait list until the
  current group is torn down.
- **Consistency.** When the barrier closes, every member sees the same
  participant list and the same per-node rank (`GROUP_RANK`).
- **A store.** Members share a `torch.distributed.Store` used to publish
  `MASTER_ADDR` / `MASTER_PORT` and (by default) to back
  `init_process_group` itself.

`--nnodes` is that `(min, max)` pair:

| You pass | min | max | When the barrier closes |
|----------|-----|-----|-------------------------|
| `--nnodes=2` | 2 | 2 | As soon as the 2nd agent joins (max hit). |
| `--nnodes=1:4` | 1 | 4 | At 4 immediately, or at ≥1 plus `last_call_timeout`. |
| `--standalone` (implies 1) | 1 | 1 | Immediately; local store only. |

This repo always uses a **fixed** integer, so `min == max`. Elastic
`MIN:MAX` would need a controller that can add/remove pods mid-run; the
Indexed Job / StatefulSet / JobSet templates here do not.

Default join timeout is **600s** (`--rdzv_conf=join_timeout=…`). If a GPU
pod is still pulling the NGC image after that, rendezvous fails with
`RendezvousTimeoutError` / `RendezvousConnectionError`. Raise
`join_timeout` (and the TCPStore `read_timeout`, default 60s) if scheduling
or pulls are slow.

### 3 — How the c10d store comes up (store host, not rank 0)

`--rdzv_backend=c10d` means “use an in-process `TCPStore` at
`--rdzv_endpoint`. No etcd.”

On each agent:

1. Parse `host:port` (port defaults to **29400** if omitted — this repo
   always passes **29500**).
2. Decide `is_host`:
   - `--rdzv_conf=is_host=1` / `0` if you set it (this repo does not).
   - Otherwise: true if `host` matches this machine (hostname, FQDN, or any
     local IP). Headless DNS `pytorch-ddp-multi-0.pytorch-ddp-multi` resolves
     to pod 0’s IP, so **only index 0** should match.
3. Index 0 constructs `TCPStore(..., is_master=True)` and binds
   `:29500`. Everyone else constructs `TCPStore(..., is_master=False)` and
   connects to that address.
4. If the hostname heuristic is wrong (CNAME, IPv6-only, hostname ≠
   endpoint), the “host” attempt fails and c10d retries once as a client.
   If **nobody** is server, every agent blocks on connect until
   `read_timeout`.

The store is just a compare-and-swap key/value used to publish rendezvous
state under `torch.rendezvous.<rdzv_id>`. Heartbeats (default every 5s,
dead after 3 misses) drop crashed agents from an in-progress join.

This TCPStore is the **control-plane** store. It is not NCCL and it is not
yet `RANK=0`.

### 4 — How ranks are assigned (the actual “master”)

Once `min`/`max` is satisfied, c10d **sorts** the participant descriptors
and numbers them:

```text
GROUP_RANK = index of this node in sorted(participants)
```

A descriptor is `(addr, pid, local_id)`. `addr` is `--local_addr` if you
set it, otherwise `socket.getfqdn()` (the pod hostname / FQDN). Sorting is
lexicographic. With this repo’s hostnames that usually means:

```text
pytorch-ddp-multi-0  →  GROUP_RANK 0
pytorch-ddp-multi-1  →  GROUP_RANK 1
```

That is a **side effect of the hostname sort**, not of `--node_rank` and
not of who hosted the store. If FQDNs sort differently, or a re-rendezvous
runs after a restart, the same pod can get a different `GROUP_RANK`.
**Ranks are not stable.**

Then each agent spawns `--nproc_per_node` workers and stamps env vars:

```text
LOCAL_RANK        = 0 … nproc-1          (GPU index on this pod)
LOCAL_WORLD_SIZE  = nproc_per_node
GROUP_RANK        = node rank from the sort above
WORLD_SIZE        = nnodes × nproc_per_node
RANK              = GROUP_RANK × nproc_per_node + LOCAL_RANK
```

Example, 2 pods × 8 GPUs:

| Pod | GROUP_RANK | LOCAL_RANK | global RANK |
|-----|------------|------------|-------------|
| `…-0` | 0 | 0…7 | 0…7 |
| `…-1` | 1 | 0…7 | 8…15 |

Global **RANK 0** is always `(GROUP_RANK=0, LOCAL_RANK=0)`.

That node then publishes the process-group bootstrap into the store:

1. Rank-0 agent binds a (usually shared) TCPStore on its own address and a
   fresh port.
2. It writes `MASTER_ADDR` = its `addr` (FQDN / `--local_addr`) and
   `MASTER_PORT` = that port.
3. Every other agent reads those two keys.
4. Each worker inherits them. `dist.init_process_group("nccl")` in
   `train_ddp_min.py` uses them — you do not pass `rank=` or `world_size=`.

So “master election” in this stack is:

```text
you pin the store to K8s index 0
        ↓
all agents join the same rdzv_id on that store
        ↓
c10d sorts (fqdn, pid) → GROUP_RANK
        ↓
GROUP_RANK 0 / LOCAL_RANK 0 becomes RANK 0
        ↓
that process publishes MASTER_ADDR:MASTER_PORT
        ↓
workers call init_process_group and NCCL starts
```

`--standalone` collapses the whole chain onto one pod: local store, one
group, `RANK = LOCAL_RANK`.

### 5 — Walk-through (this repo’s 2×1 smoke job)

```text
kubectl apply -f training/multi-node-ddp-job.yaml
        │
        ├─ Service pytorch-ddp-multi  (headless, port 29500, publishNotReady)
        └─ Job parallelism=2, Indexed
                │
                ├─ pod -0  index=0  ── binds TCPStore on :29500
                └─ pod -1  index=1  ── dials pytorch-ddp-multi-0.pytorch-ddp-multi:29500
                        │
                        │  both: torchrun --nnodes=2 --nproc_per_node=1
                        │               --rdzv_backend=c10d
                        │               --rdzv_endpoint=…-0.…:29500
                        │               --rdzv_id=pytorch-ddp-multi
                        │
                        ▼
                barrier: 2/2 agents present → complete immediately
                        │
                        ▼
                sort hostnames → GROUP_RANK {0,1}
                spawn 1 worker each
                RANK 0 publishes MASTER_ADDR/MASTER_PORT
                        │
                        ▼
                train_ddp_min.py: init_process_group("nccl")
                all_reduce(1-element tensor) → "DDP smoke OK"
```

If pod 1 starts first it **blocks** on connecting to the store until pod 0
listens (or `read_timeout` / `join_timeout` fires). That is expected.

### 6 — Elastic `MIN:MAX` and re-rendezvous

Not used here; this is what `--nnodes=1:4 --max-restarts=3` would do.

- Training starts at `min` members; extra nodes up to `max` can join.
- A join, leave, or worker crash tears **every** surviving worker down.
- Agents re-enter rendezvous, get a **new** `GROUP_RANK` / `RANK` /
  `WORLD_SIZE`, and relaunch the script.
- The script must reload a checkpoint; ranks from the previous round are
  meaningless.
- Late nodes that miss the current round sit on the wait list until the
  group is destroyed; they cannot start a parallel job under the same
  `--rdzv_id`.

With `--max-restarts=0` (this repo) any worker death fails the job. Outer
retries are Kubernetes `backoffLimit` / JobSet `maxRestarts`.

### 7 — Failure modes you will actually see

| Symptom | Usual cause |
|---------|-------------|
| Hang, then `RendezvousConnectionError` / store timeout | Index 0 not scheduled, image still pulling, headless DNS not ready (`publishNotReadyAddresses` missing), or `NCCL_SOCKET_IFNAME` / wrong `--rdzv_endpoint`. |
| `RendezvousTimeoutError` after ~600s | Fewer than `--nnodes` agents joined (`NNODES` ≠ Job `parallelism` / STS `replicas`). |
| Two jobs merge into one world | Same `--rdzv_id` **and** same `--rdzv_endpoint` still up. Change the id or delete the old pods. |
| `unrecognized arguments: --local-rank=` | Training script’s argparse only accepts `--local_rank`. Prefer `os.environ["LOCAL_RANK"]`. |
| NCCL timeout after rendezvous succeeded | Fabric / `NCCL_*` in `training/training-configmap.yaml`, not torchrun. Run `validation/nccl-test-multinode.yaml` first. |

NCCL is a later plane. Rendezvous uses the pod network (Service DNS +
container port 29500). Collectives use the GPU fabric (`NCCL_SOCKET_IFNAME`,
`NCCL_IB_*`). A job can pass rendezvous and still fail NCCL.

## torchrun flags

`torchrun` is the PyTorch elastic launcher (`python -m torch.distributed.run`).
Every training / NCCL job in this directory starts it. It spawns one process
per local worker, sets the distributed env vars (`LOCAL_RANK`, `RANK`,
`WORLD_SIZE`, `MASTER_ADDR`, …), and runs the rendezvous so all nodes join
the same process group.

Official reference: [torchrun (Elastic Launch)](https://docs.pytorch.org/docs/stable/elastic/run.html).
Flags below match `torch.distributed.run` as of PyTorch 2.13 / current `main`.

**Conventions**

- Dashed and underscored names are aliases (`--nproc-per-node` =
  `--nproc_per_node`). Manifests in this repo use underscores.
- Most flags also read `PET_<FLAG>` if the CLI value is omitted
  (`PET_NNODES`, `PET_NPROC_PER_NODE`, `PET_RDZV_BACKEND`, …).
- After the flags comes the training script, then that script’s own args.
- `--standalone` ignores any `--rdzv-*` you also pass and picks a local
  c10d store on a free port.

**What this repo actually passes**

| Pattern | Flags | Manifests |
|---------|-------|-----------|
| Single-node smoke | `--standalone --nnodes=1 --nproc_per_node=$NPROC` | `training/single-node-ddp-job.yaml`, `workers/example-training-worker.yaml`, `workers/overlays/full-node-training-patch.yaml`, `../07-scheduling/kueue/example-training-job-kueue.yaml` |
| Multi-node DDP | `--nnodes --nproc_per_node --node_rank --rdzv_backend=c10d --rdzv_endpoint --rdzv_id` | `training/multi-node-ddp-job.yaml`, `training/multi-node-ddp-statefulset.yaml`, `training/multi-node-jobset.yaml`, `validation/nccl-test-multinode.yaml` |

`--node_rank` is only consumed when `--rdzv_backend=static`. These multi-node
jobs use **c10d**: Kubernetes index 0 is the **store host** (`--rdzv_endpoint`),
and `GROUP_RANK` / `RANK=0` are assigned after the barrier (hostname sort).
See [How torchrun actually runs a job](#how-torchrun-actually-runs-a-job).
Keep `--rdzv_endpoint` pointed at **index 0** (`…-0.<headless-svc>:29500`).

---

### Worker / cluster size

#### `--nnodes`

**Default:** `1:1`

How many nodes (pods, in this cluster) join the job.

- A single integer (`2`) means a fixed size: wait for exactly that many
  agents, then start.
- `MIN:MAX` (`1:4`) is elastic: start when at least `MIN` nodes have
  rendezvous’d, allow up to `MAX`. On join/leave, torchrun kills every
  worker and relaunches with a new `RANK` / `WORLD_SIZE`.

This repo always uses a fixed integer (`1` on smoke jobs, `2` on multi-node
examples via the `NNODES` env). Elastic `MIN:MAX` needs a job controller
that can add/remove pods mid-run; the Indexed Job / StatefulSet / JobSet
templates here do not.

World size = `nnodes × nproc_per_node` (homogeneous local world size is
required — every node must spawn the same number of workers).

#### `--nproc-per-node` / `--nproc_per_node`

**Default:** `1`

How many worker processes to spawn **on this node**. For GPU training this
must be ≤ the number of GPUs visible to the container; worker `i` binds to
GPU `i` (`LOCAL_RANK` 0 … nproc−1).

Accepted values:

| Value | Meaning |
|-------|---------|
| integer | Exact process count |
| `gpu` | `torch.cuda.device_count()` |
| `cpu` | CPU count |
| `xpu` | Intel XPU count |
| `auto` | GPU if CUDA is up, else XPU if present, else CPU |
| custom accelerator name | That backend’s `device_count()` |

This repo sets an integer from `NPROC_PER_NODE` (default `1` so the job
schedules on any healthy GPU node). Full-node overlays set it to `8` and
request `nvidia.com/gpu: 8`. Prefer the integer over `gpu` in Kubernetes:
the device plugin already limits visibility, but an explicit count matches
the pod `resources` and fails fast if they drift.

If `nproc_per_node > 1` and `OMP_NUM_THREADS` is unset, torchrun forces
`OMP_NUM_THREADS=1` to avoid oversubscribing the node. This repo sets
`OMP_NUM_THREADS=8` in `training/training-configmap.yaml` so that default
does not apply.

---

### Rendezvous

Rendezvous is how every node’s torchrun agent finds the others and agrees
on ranks before workers call `dist.init_process_group`. Multi-node jobs
must share the same `--rdzv-id`, `--rdzv-backend`, and `--rdzv-endpoint`.
Mechanics (barrier, store host vs `RANK=0`, timeouts):
[How torchrun actually runs a job](#how-torchrun-actually-runs-a-job).

#### `--rdzv-backend` / `--rdzv_backend`

**Default:** `static`

Which rendezvous implementation to use.

| Backend | Role |
|---------|------|
| `c10d` | In-process TCP store hosted at `--rdzv-endpoint`. No extra server. **Use this.** |
| `static` | Fixed membership: you supply `--node-rank`, `--master-addr`, `--master-port` on every node. No elasticity. |
| `etcd-v2` | External etcd (API v2 must be enabled). Rarely worth it on Kubernetes. |
| `etcd` | Legacy etcd handler; maintenance mode, will be removed. |

`--standalone` forces `c10d`. This repo’s multi-node manifests set
`--rdzv_backend=c10d` and point the endpoint at pod 0.

#### `--rdzv-endpoint` / `--rdzv_endpoint`

**Default:** empty (static backend then uses `--master-addr`:`--master-port`)

`host:port` of the rendezvous store. Any participant can host it; pick a
stable, reachable address. If the port is omitted, c10d defaults to
**29400** (not 29500).

This repo uses headless-Service DNS on port **29500**:

| Manifest | Endpoint |
|----------|----------|
| `training/multi-node-ddp-job.yaml` | `pytorch-ddp-multi-0.pytorch-ddp-multi:29500` |
| `training/multi-node-ddp-statefulset.yaml` | `pytorch-ddp-sts-0.pytorch-ddp-sts:29500` |
| `training/multi-node-jobset.yaml` | `pytorch-ddp-jobset-workers-0-0.pytorch-ddp-jobset:29500` |
| `validation/nccl-test-multinode.yaml` | `nccl-test-0.nccl-test:29500` |

`publishNotReadyAddresses: true` on those Services is required so pod 0
resolves before it is Ready. Port `0` (`localhost:0`) means “pick a free
port” and is only valid for single-node / `--standalone`.

IPv6 must be written `[addr]:port`.

#### `--rdzv-id` / `--rdzv_id`

**Default:** `none`

User-defined job id. Every node of the **same** job must pass the same
value; a different id is a different worker group (two jobs will not
join each other). `--standalone` replaces this with a random UUID.

This repo sets a per-manifest constant (`pytorch-ddp-multi`,
`pytorch-ddp-sts`, `pytorch-ddp-jobset`, `nccl-test`). If you rerun two
jobs that share an id and an endpoint while the first rendezvous is still
up, they can merge. Change the id (or delete the previous pods) between
overlapping experiments.

#### `--rdzv-conf` / `--rdzv_conf`

**Default:** empty

Comma-separated `key=value` options forwarded to the rendezvous handler,
for example:

```text
--rdzv_conf=timeout=900,join_timeout=600
```

Useful keys (c10d / dynamic rendezvous): `timeout` (overall, seconds),
`join_timeout`, `last_call_timeout`, `read_timeout`. Static rendezvous
also receives `rank` from `--node-rank` automatically.

Not set in this repo. Raise `timeout` if nodes are slow to schedule
(GPU nodes coming up, image pulls) and rendezvous dies with a store
connection timeout.

#### `--standalone`

**Default:** off (flag, no value)

Single-node shortcut. Forces:

- `--rdzv-backend=c10d`
- `--rdzv-endpoint=localhost:0` (random free port)
- `--rdzv-id=<uuid>`

Any `--rdzv-*` you also pass is ignored. Use it for one-pod jobs so you
do not hard-code a port and so two pods on the same node cannot
accidentally share a store.

This repo uses `--standalone` on every single-node training job.

---

### Launch, restarts, process model

#### `--max-restarts` / `--max_restarts`

**Default:** `0`

How many times the **whole worker group** may restart after a worker,
agent, or (with elasticity) membership change. `0` = fail the job on the
first worker death. On a restart every surviving worker is killed and
relaunched; ranks are **not** stable across restarts.

Leave at `0` for these smoke jobs (and set Job `backoffLimit` /
JobSet `maxRestarts` as the outer retry). Raise it only if the training
script reloads a checkpoint at start — otherwise you replay lost work.

#### `--monitor-interval` / `--monitor_interval`

**Default:** `0.1` seconds

How often the agent polls worker process state. Lower is more
responsive; higher is slightly cheaper. Do not change unless you are
debugging agent CPU on huge local world sizes.

#### `--start-method` / `--start_method`

**Default:** `spawn`  
**Choices:** `spawn`, `fork`, `forkserver`

`multiprocessing` start method for workers. `spawn` is the safe default
with CUDA (fork + CUDA is undefined). Do not switch to `fork` in the
NGC PyTorch GPU image.

#### `--event-log-handler` / `--event_log_handler`

**Default:** `null`

Name of a registered Torch Elastic event handler
([elastic events](https://docs.pytorch.org/docs/stable/elastic/events.html)).
`null` discards events. Only needed if you plug rendezvous / restart
events into an external sink.

#### `--role`

**Default:** `default`

Label for this worker group. Appears in log prefixes
(`[default0]: …`) and in `ROLE_RANK` / `ROLE_WORLD_SIZE`. Use distinct
roles only if one `torchrun` invocation launches more than one kind of
process (uncommon; this repo is a single homogeneous trainer role).

#### `-m` / `--module`

**Default:** off

Treat `training_script` as a module (`python -u -m pkg.train`) instead
of a file path. Mutually exclusive with `--no-python`.

#### `--no-python` / `--no_python`

**Default:** off

Do not prepend `python -u`. The “script” is executed as a binary /
shell entrypoint. Use for a compiled trainer or a wrapper script with a
shebang. Cannot be combined with `--module`.

#### `--run-path` / `--run_path`

**Default:** off

Load the script with `runpy.run_path` **in the agent’s interpreter**
(absolute path required). Takes precedence over `--no-python`. Useful
when you must not spawn a second Python. Rare in Kubernetes; the NGC
image already has a dedicated worker process per rank.

---

### Logging

By default every rank’s stdout/stderr hit the container log interleaved,
with no rank prefix.

#### `--log-dir` / `--log_dir`

**Default:** unset (temp dir)

Base directory for per-rank log files. A job-level subdirectory is
created under it (prefixed with `--rdzv-id`). Point this at a writable
volume (checkpoint PVC) if you want rank logs to survive the pod.

#### `-r` / `--redirects`

**Default:** `0` (no redirect)

Write stdio to files under `--log-dir` **instead of** the console.

| Value | Effect |
|-------|--------|
| `0` | No redirect |
| `1` | stdout |
| `2` | stderr |
| `3` | both |
| `0:1,1:2` | Per-local-rank: rank 0 stdout, rank 1 stderr |

`kubectl logs` will then be empty for redirected streams — use files.

#### `-t` / `--tee`

**Default:** `0`

Same value syntax as `--redirects`, but streams go to **both** the log
file and the console. Prefer `--tee 3` when you want rank files *and*
`kubectl logs`.

Tee’d console lines are prefixed with `[${role_name}${local_rank}]:`
(e.g. `[default3]:`).

#### `--log-line-prefix-template` / `--log_line_prefix_template`

**Default:** empty → `[${role_name}${local_rank}]:`

Template for the tee prefix. Macros: `${role_name}`, `${local_rank}`,
`${rank}`, `${hostname}`. Also settable via
`TORCHELASTIC_LOG_LINE_PREFIX_TEMPLATE` (CLI wins).

On a multi-node job `${hostname}` is the pod name, which is what you
want when hunting a bad NCCL rank:

```text
--tee=3 --log-line-prefix-template='${hostname}:${rank}: '
```

#### `--local-ranks-filter` / `--local_ranks_filter`

**Default:** empty (all ranks)

Comma-separated **local** ranks whose stdout/stderr still go to the
console (`0,1`). Does not affect files written by `--redirects` / `--tee`.
Use to silence 8-GPU chatter while keeping rank-0 progress.

#### `--duplicate-stdout-filters` / `--duplicate_stdout_filters`

**Default:** empty (duplicate nothing)

Copy stdout lines that contain any of the comma-separated substrings
into a sidecar file. `,,` escapes a literal comma. Empty list = no copy.

#### `--duplicate-stderr-filters` / `--duplicate_stderr_filters`

**Default:** empty

Same as above for stderr (NCCL warnings, CUDA asserts).

#### `--logs-specs` / `--logs_specs`

**Default:** unset → `DefaultLogsSpecs`

Name of a `torchrun.logs_specs` entry point. Lets a library replace the
whole logging implementation. Leave unset unless you ship a custom
plugin.

---

### Static rendezvous / addressing

These exist for `torch.distributed.launch` compatibility. They apply
when `--rdzv-backend=static` (or when c10d has no `--rdzv-endpoint` and
falls back). This repo’s multi-node jobs use **c10d + `--rdzv-endpoint`**,
so `--master-addr` / `--master-port` / `--node-rank` are not the source
of truth — but `--node-rank` is still passed so a backend switch keeps
working.

#### `--node-rank` / `--node_rank`

**Default:** `0`

This node’s rank in a **static** rendezvous (`0 … nnodes-1`). Ignored
(with a warning if non-zero) when `--rdzv-backend` is not `static`.

This repo still sets it from `JOB_COMPLETION_INDEX` (Indexed Job / JobSet)
or the StatefulSet hostname ordinal (`${HOSTNAME##*-}`), but under c10d
that value is **not** `GROUP_RANK`. Index **0** is only the store host
(`--rdzv_endpoint`). `GROUP_RANK` / `RANK=0` come from the post-barrier
sort.

#### `--master-addr` / `--master_addr`

**Default:** `127.0.0.1`

Hostname or IP of the static-rendezvous master (typically node rank 0).
IPv6: `[0:0:0:0:0:0:0:1]`. Unused when `--rdzv-endpoint` is set for
c10d. Workers still see `MASTER_ADDR` in the environment; torchrun
fills that from rendezvous, not from this flag, under c10d.

#### `--master-port` / `--master_port`

**Default:** unset → **29500** (after parse)

TCP port on `--master-addr` for the static store. Unused when
`--rdzv-endpoint` includes a port. This repo’s Services listen on
**29500** to match that default.

#### `--local-addr` / `--local_addr`

**Default:** unset → machine FQDN

Address this node advertises for incoming store / TCP connections. Set
it when the pod FQDN is wrong (multiple NICs, IPv6-only, or the
container hostname is not the address peers should dial). On this
cluster the headless Service DNS is the right peer address; leave this
unset unless rendezvous connects to the wrong interface.

---

### NUMA, signals, device visibility

#### `--numa-binding` / `--numa_binding`

**Default:** unset (no binding)  
**Choices:** `node`, `socket`, `exclusive`, `core-complex`

Pin each worker (and its threads) to CPUs near the GPU whose index
equals that worker’s `LOCAL_RANK`. Typical gain is 1–10% on multi-socket
DGX; some workloads see more, some none.

| Mode | Binding |
|------|---------|
| `node` | All CPUs on the NUMA node that holds that GPU. **Start here.** |
| `socket` | All CPUs on every NUMA node of that GPU’s socket. Same as `node` when there is one NUMA node per socket. |
| `exclusive` | Partition that NUMA node’s cores evenly across GPUs on it; workers do not share cores. |
| `core-complex` | One L3-sharing core complex per worker, different complexes when possible. |

Worth adding on full-node (`nproc=8`) overlays:

```text
torchrun --standalone --nnodes=1 --nproc_per_node=8 --numa-binding=node …
```

Needs a working `libnuma` in the image (NGC PyTorch has it).

#### `--signals-to-handle` / `--signals_to_handle`

**Default:** `SIGTERM,SIGINT,SIGHUP,SIGQUIT`

Signals the agent traps and forwards to workers. Kubernetes sends
**SIGTERM** on pod delete, then SIGKILL after `terminationGracePeriodSeconds`.
Keep `SIGTERM` in this list. Add `SIGUSR1,SIGUSR2` only if something
(Slurm-style preemption) uses those; kubelets do not.

#### `--shutdown-timeout` / `--shutdown_timeout`

**Default:** unset → `TORCH_ELASTIC_SHUTDOWN_TIMEOUT` or **30** seconds

How long to wait for workers to exit after a forwarded signal before
SIGKILL. Keep this **below** the pod’s `terminationGracePeriodSeconds`
(30s on the StatefulSet) so torchrun finishes before kubelet SIGKILLs
the container.

#### `--virtual-local-rank` / `--virtual_local_rank`

**Default:** off

Set `LOCAL_RANK=0` for every worker and shrink `CUDA_VISIBLE_DEVICES`
so each process only sees its assigned GPU as `cuda:0`. Use when the
training script assumes a single visible device (some NGC examples,
frameworks that ignore `LOCAL_RANK`). Leave off for this repo’s
scripts: they call `torch.cuda.set_device(LOCAL_RANK)`.

---

### Shell helpers and positional args

#### `--print-completion` / `--print_completion`

Print a bash / zsh / tcsh completion script to stdout and exit.
Requires the optional `shtab` package. Not used in cluster jobs.

```bash
torchrun --print-completion bash > ~/.local/share/bash-completion/completions/torchrun
```

#### `training_script` (positional)

Path (or module name with `-m`) of the program each worker runs. This
repo mounts example scripts from ConfigMap `pytorch-example-scripts` at
`/workspace/examples/` and launches `/workspace/examples/train_ddp_min.py`
(NCCL test: `/scripts/nccl_bench.py`).

From PyTorch 2.0, torchrun also passes `--local-rank=<n>` into the
script. Prefer `os.environ["LOCAL_RANK"]` (what `train_ddp_min.py`
does). If you parse argv, accept both `--local-rank` and `--local_rank`.

#### `training_script_args` (remainder)

Everything after the script name is forwarded unchanged to each worker.
Put trainer hyperparameters here (`--epochs 10 --batch-size 32`), not
torchrun flags.

```bash
torchrun --standalone --nnodes=1 --nproc_per_node=8 \
  /workspace/train.py --epochs 10 --lr 1e-4
```

---

### Environment variables torchrun injects

Not flags, but what the training script actually consumes
(`dist.init_process_group()` reads these; you do not pass `RANK` by hand):

| Variable | Meaning |
|----------|---------|
| `LOCAL_RANK` | Rank within this node (`0 … nproc-1`). GPU index. |
| `RANK` | Global rank. **Not stable** across restarts or elasticity. |
| `WORLD_SIZE` | `nnodes × nproc_per_node` (changes if `nnodes` is a range). |
| `LOCAL_WORLD_SIZE` | Equals `--nproc-per-node`. |
| `GROUP_RANK` | This node’s rank in the worker group (`0 … nnodes-1` when one group per node). |
| `ROLE_RANK` / `ROLE_WORLD_SIZE` | Rank / size within `--role`. |
| `MASTER_ADDR` / `MASTER_PORT` | Rank-0 host and store port for `init_process_group`. |
| `TORCHELASTIC_RESTART_COUNT` | Restarts so far. |
| `TORCHELASTIC_MAX_RESTARTS` | Value of `--max-restarts`. |
| `TORCHELASTIC_RUN_ID` | Same as `--rdzv-id`. |
| `PYTHON_EXEC` | If set **before** torchrun, workers are launched with this interpreter instead of `sys.executable`. |

Related env in `training/training-configmap.yaml` is **not** torchrun:
`NCCL_*`, `OMP_NUM_THREADS`, `TORCH_DISTRIBUTED_DEBUG` configure NCCL /
OpenMP / c10d after the process group exists.

---

### Env torchrun itself honors

| Variable | Effect |
|----------|--------|
| `PET_<FLAG>` | Default for the matching CLI flag when the flag is omitted. |
| `TORCHELASTIC_LOG_LINE_PREFIX_TEMPLATE` | Default tee prefix (overridden by `--log-line-prefix-template`). |
| `TORCH_ELASTIC_SHUTDOWN_TIMEOUT` | Default for `--shutdown-timeout`. |
| `OMP_NUM_THREADS` | If unset and `nproc_per_node > 1`, torchrun sets it to `1`. |
| `PYTHON_EXEC` | Worker interpreter. |

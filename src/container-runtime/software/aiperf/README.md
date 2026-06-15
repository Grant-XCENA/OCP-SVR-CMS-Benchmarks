# AIPerf + LMCache — OCP CMS Inference Benchmark

OCP SRV CMS container wrapper for [AIPerf](https://github.com/ai-dynamo/aiperf)
with a separated [LMCache](https://github.com/LMCache/LMCache) serving engine and
a **pluggable KV cache backend**. Benchmarks LLM inference serving performance
across whichever KV cache tier you select — CPU offload, disk, Redis, Mooncake,
InfiniStore, or CXL shared memory — fully containerized end-to-end.

The KV cache backend is chosen with a single `LMCACHE_BACKEND` setting. The
bundled `docker-compose.yml` ships a complete, ready-to-run example using
[Maru](https://github.com/xcena-dev/maru) CXL shared memory as the backend; swap
in any other backend by changing that one line and supplying its connection
settings.

In addition to standard single-run benchmarking, this wrapper supports a
**KV cache hit-rate parameter sweep**: it drives the cache from a high hit rate
(e.g. 95%) down to a low one (e.g. 5%) across configurable levels, measuring the
actual hit rate at each step from the server's Prometheus metrics, alongside GPU
utilization from a DCGM exporter. See "KV Cache Parameter Sweep" below.

> **GPU vendor note.** This stack is built and tested against **NVIDIA** GPUs, but
> nothing in the *methodology* is NVIDIA-specific — AIPerf is a client-side
> workload generator that never touches the GPU, and the sweep's cache-hit
> measurement reads vendor-neutral vLLM Prometheus counters. Bringing it to AMD
> (ROCm) parity is tractable but not free; it would require: (1) a ROCm vLLM image
> in place of the CUDA `Dockerfile.server`; (2) ROCm device plumbing in compose
> (`/dev/kfd` + `/dev/dri` and the `video`/`render` groups) instead of the
> `nvidia` device reservation and `nvidia-container-toolkit`; (3) replacing the
> DCGM exporter with the **AMD SMI exporter** and repointing the sweep's GPU-util
> scrape at the AMD metric names instead of `DCGM_FI_DEV_GPU_UTIL`; and (4)
> validating LMCache's GPU-side path on ROCm, which is less mature than its CUDA
> path. The AIPerf client, the sweep logic, and the results parser need **no**
> changes. The Maru CXL backend itself is GPU-vendor-neutral (it is CPU/CXL
> memory-side); only the LMCache↔GPU glue is the open question.



## Architecture

At its core this is three roles: a **load generator** (AIPerf), a **system under
test** (vLLM + LMCache), and a **pluggable KV cache backend** behind LMCache. A
fourth container (DCGM exporter) provides GPU telemetry for the sweep. The KV
cache backend is whatever you select with `LMCACHE_BACKEND` — CPU offload, disk,
Redis, Mooncake, InfiniStore, Maru, or your own. Only some backends need a
dedicated container; the rest run inside the server.

```
┌──────────────────────────┐  ┌──────────────────────────┐  ┌─────────────────────┐
│  KV cache backend        │  │  lmcache-server-gpu      │  │  aiperf-client      │
│  (pluggable, optional    │  │  (System Under Test)     │  │  (Load Generator)   │
│   container)             │  │                          │  │                     │
│                          │  │  vLLM inference engine   │  │  AIPerf profile     │
│  Selected by             │  │  + LMCache KV cache      │  │  (HTTP requests)    │
│  LMCACHE_BACKEND.        │  │                          │  │                     │
│  Some backends run in    │  │  Exposes: :30080/v1/...  │◄─│  Fires requests     │
│  the server (cpu/disk);  │  │  Exposes: :30080/metrics │  │  Collects JSON/CSV  │
│  others are external     │◄─│                          │  │  Scrapes metrics    │
│  (Redis, Mooncake,       │  │  KV cache backend:       │  │                     │
│  InfiniStore, Maru, …).  │  │  <backend connection>    │  │  OCP CMS reporting  │
└──────────────────────────┘  └──────────────────────────┘  └─────────────────────┘
                                          ▲                              │
                                          │                              │ scrapes
                                  NVIDIA GPU(s)                          ▼
                                          ▲                  ┌─────────────────────┐
                                          │                  │  dcgm-exporter      │
                                          └──────────────────│  (GPU telemetry)    │
                                            DCGM_FI_DEV_*    │  :9400/metrics      │
                                                             └─────────────────────┘
```

The client always talks to the server on `:30080` (requests + cache metrics) and
to DCGM on `:9400` (GPU util). Everything below that line is backend-specific.

### Provided example: Maru (CXL shared memory) via docker compose

The bundled `docker-compose.yml` wires up the **Maru** backend as a complete,
ready-to-run example of an external KV cache backend. Maru adds a dedicated
container and CXL device plumbing:

```
┌────────────────────────┐  ┌──────────────────────────┐
│  maru                  │  │  lmcache-server-gpu      │
│  (CXL KV Cache Engine) │  │                          │
│                        │  │  KV cache backend:       │
│  maru-resource-manager │  │  maru://localhost:5555   │
│  (C++, port 9850)      │  │                          │
│  Manages DAX pool      │  │                          │
│                        │  │                          │
│  maru-server           │◄─│                          │
│  (Python, port 5555)   │  │                          │
│  KV metadata           │  │                          │
│                        │  │                          │
│  /dev/dax* ◄───────────│──│─ zero-copy mmap ─────────│
└────────────────────────┘  └──────────────────────────┘
         ▲
    CXL Device (/dev/dax*)
```

To run a different backend, change `LMCACHE_BACKEND` (see the backend table
below) and supply that backend's connection settings; the Maru container and DAX
mapping are only needed for `LMCACHE_BACKEND=maru`.

Startup order (Maru example): **maru** → **dcgm-exporter** →
**lmcache-server-gpu** → **aiperf-client**. With a non-container backend (e.g.
`cpu_offload`), there is no maru container and the order is **dcgm-exporter** →
**lmcache-server-gpu** → **aiperf-client**.

All containers run with `network_mode: host`, so every `localhost:<port>`
reference resolves on the shared host network. The client scrapes the server's
cache metrics on `:30080/metrics` and GPU utilization from DCGM on `:9400`.


## Prerequisites

### Build the OCP CMS base image (one-time)

```bash
cd src/container-runtime/utils
docker build -t ocp-cms-base:latest -f Dockerfile.base .
```

### Hardware

- NVIDIA GPU(s) with CUDA drivers + `nvidia-container-toolkit`
- For Maru: CXL device with `/dev/dax*` access
- For GPU-utilization measurement: DCGM-compatible driver (the bundled
  `dcgm-exporter` image must match your driver; see Troubleshooting)

### Authentication

```bash
HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

For gated models (Llama, Mistral), you must also accept the model license at
the model's HuggingFace page before the token will work.

## Quick Start

```bash
cd src/container-runtime/software/aiperf
cp EDITME.env .env
nano .env   # set HF_TOKEN, choose LMCACHE_BACKEND, optionally enable the sweep

docker compose build && docker compose up
```

Results land in `./results` (or `HOST_RESULTS_DIR`).

## Swapping Backends

Change `LMCACHE_BACKEND` in `.env`, rebuild the server only:

```bash
docker compose build lmcache-server-gpu && docker compose up
```

| `LMCACHE_BACKEND=` | What it does | Extra config |
|---|---|---|
| `none` | Plain vLLM, no caching (baseline) | — |
| `cpu_offload` | KV cache → CPU RAM (default) | — |
| `disk` | KV cache → CPU RAM + local disk | — |
| `redis` | KV cache → Redis | `LMCACHE_REMOTE_HOST`, `LMCACHE_REMOTE_PORT` |
| `lmserver` | KV cache → LMCache server | `LMCACHE_REMOTE_HOST`, `LMCACHE_REMOTE_PORT` |
| `mooncake` | KV cache → Mooncake store | `LMCACHE_REMOTE_HOST/PORT`, `LMCACHE_MOONCAKE_*` |
| `infinistore` | KV cache → InfiniStore (RDMA) | `LMCACHE_REMOTE_HOST/PORT`, `LMCACHE_INFINISTORE_DEVICE` |
| `maru` | KV cache → Maru CXL shared memory | `LMCACHE_MARU_HOST/PORT/POOL_SIZE` + DAX devices |
| `custom` | Your own YAML | `LMCACHE_CONFIG_FILE_CONTENT` (base64) |

## Maru (CXL Shared Memory)

[Maru](https://github.com/xcena-dev/maru) stores KV cache in CXL shared memory
via `/dev/dax*` devices. Zero-copy reads, no network serialization. Maru is fully
containerized — no host installation required. The `maru` container runs both the
resource manager (C++ binary managing the DAX memory pool) and the metadata
server (Python, managing KV entries).

### DAX Device Mapping (CRITICAL)

Even with `privileged: true`, the application only *uses* the DAX device(s) you
point it at. Map each DAX device in `docker-compose.yml` under **both** the `maru`
and `lmcache-server-gpu` services:

```yaml
  maru:
    devices:
      - /dev/dax0.0:/dev/dax0.0

  lmcache-server-gpu:
    devices:
      - /dev/dax0.0:/dev/dax0.0
```

Both containers need the same DAX devices — Maru's resource manager initializes
the shared memory regions, and LMCache's handler mmaps the same regions for
zero-copy access. Find your devices with `ls /dev/dax*` on the host.

> **Restricting which DAX device Maru uses:** with `privileged: true`, Maru's
> resource manager *discovers* every `/dev/dax*` on the host (you will see all of
> them listed in its startup log). Discovery is not the same as use. To pin the
> pool to a single device, restrict it in Maru's own configuration rather than at
> the container device layer. If you need it to not even *see* the other devices,
> drop `privileged` and use an explicit `devices:` list plus the capabilities the
> DAX mmap path requires (`SYS_ADMIN`, often `IPC_LOCK`) — but note that once
> `SYS_ADMIN` is added, the isolation gain over `privileged` is marginal.

### Container Configuration

```bash
LMCACHE_BACKEND=maru
LMCACHE_MARU_HOST=localhost
LMCACHE_MARU_PORT=5555
LMCACHE_MARU_POOL_SIZE=200    # GiB of CXL pool for KV cache
```

### Multiple Maru instances on one host

Because all containers use host networking, running more than one Maru stack on a
single host requires giving each stack its own ports. Change `MARU_RM_PORT` (and,
if needed, the metadata port) per stack so they do not collide. The maru
container's healthcheck probes the metadata port; see the healthcheck note in
Troubleshooting.

## KV Cache Parameter Sweep

The sweep drives the KV cache across a gradient of target hit rates and records
the *measured* hit rate and GPU utilization at each level. It is **opt-in**: when
`AIPERF_SWEEP_ENABLED=true`, the normal single-run benchmark is skipped and
replaced by one AIPerf invocation per sweep level.

### How it works

For each level (a target hit-rate percentage), the client:

1. Resets both cache layers on the server
   (`POST /reset_prefix_cache?reset_external=true`), so each level starts cold.
2. Snapshots the server's prefix-cache token counters.
3. Runs `aiperf profile` with the pre-tuned parameter set for that target hit
   rate (turn count, turn delay, ISL/OSL, concurrency, shared prompt length,
   conversation count, dataset entries), while sampling GPU utilization from DCGM
   in the background.
4. Snapshots the counters again and computes the **measured** hit rate as a
   delta:
   - `actual_cache_hit_pct` (primary): the external / LMCache+Maru tier, from
     `vllm:external_prefix_cache_hits_total / _queries_total`.
   - `l1_cache_hit_pct` (secondary): the vLLM GPU-resident prefix cache, from
     `vllm:prefix_cache_hits_total / _queries_total`.
5. Writes a per-level `sweep_level_info.json` and appends a row to
   `sweep_results/sweep_summary.csv`.

### Default sweep levels

```
95, 90, 85, 80, 75, 50, 25, 15, 10, 5
```

Each number is a **target KV cache hit rate** — the fraction of requested KV
that is expected to be *served from the cache* rather than recomputed. So 95%
means 95% of the KV is a cache **hit** (only 5% is recomputed), and 5% means
almost everything misses and is recomputed from scratch. Higher number = more
caching = less prefill work.

The sweep runs **one full benchmark per level**, in sequence. The default list
runs ten benchmarks; `AIPERF_SWEEP_LEVELS=95,50,5` runs three — one aiming for
95%, one for 50%, one for 5%.

You do not specify the parameters that produce each hit rate. A high hit rate
needs long multi-turn conversations, a large shared prompt, and low concurrency;
a low hit rate needs the opposite. The sweep ships with a pre-tuned parameter set
for each target percentage and selects the right one *by the percentage itself*,
so a subset like `95,50,5` still uses the correct parameters for 50% — not
whatever would sit in the second slot of the full list. Override any parameter
per level with the `AIPERF_SWEEP_*` variables below.

**Target vs. measured.** The level numbers are *targets* — the parameters are
aimed at producing them, but the real run will not land exactly on each target.
What actually happened is reported separately, measured from the server's
Prometheus counters: `Actual Cache Hit % (external/Maru)` is the measured hit rate
for the LMCache/Maru tier (the primary number), and `vLLM L1 Cache Hit %` is the
measured hit rate for vLLM's GPU-resident prefix cache. Compare the target column
to the measured columns to see how closely each level hit its mark.

### Server requirements for the sweep

The sweep depends on two server-side capabilities. The `server-entrypoint.sh`
sets these up, but they are worth understanding:

- **`VLLM_SERVER_DEV_MODE=1`** — required for the `/reset_prefix_cache` endpoint
  to exist. Without it, the per-level cache reset silently fails and levels
  contaminate each other. (The sweep still computes per-level rates from counter
  deltas, but cold-start cleanliness is lost.)
- **`PROMETHEUS_MULTIPROC_DIR`** — vLLM and LMCache run as separate processes and
  both export Prometheus metrics. This directory must exist (created clean on each
  launch) for the `lmcache:` and `vllm:external_prefix_cache_*` metrics to appear
  on `/metrics`. If it is missing, the server crashes at startup with a
  `FileNotFoundError` from `prometheus_client`.

### GPU utilization (DCGM)

GPU utilization is scraped from a bundled **dcgm-exporter** service on `:9400`,
not from `nvidia-smi` in the client. This is deliberate: the GPU is used by the
server container, and the client cannot reliably run `nvidia-smi` against a GPU it
was not granted. DCGM runs in its own container with `--gpus all` and exposes
`DCGM_FI_DEV_GPU_UTIL` over HTTP, which the host-networked client scrapes.

`DCGM_FI_DEV_GPU_UTIL` is **not** in DCGM's default metric set; the bundled
`dcgm-metrics.csv` enables it (plus memory, temperature, power, and clocks). If
DCGM is unreachable, the sweep falls back to `nvidia-smi` and then to `N/A`.

### Quick sweep example

```bash
# .env
LMCACHE_BACKEND=maru
AIPERF_MODEL=Qwen/Qwen3-32B
AIPERF_SWEEP_ENABLED=true
AIPERF_SWEEP_LEVELS=95,50,5
AIPERF_SWEEP_DRY_RUN=true     # log the commands first; set false to run for real
```

```bash
docker compose build && docker compose up
```

A dry run logs the exact `aiperf` command for each level and writes
`sweep_results/dry_run_commands.txt` without executing — useful for CI and for
validating `.env` before spending GPU time.

### Hybrid: native AIPerf sweep

Two knobs let AIPerf do more of the work natively:

- **`AIPERF_SWEEP_NUM_PROFILE_RUNS`** (with `AIPERF_SWEEP_PARAM_SWEEP_MODE`) —
  runs each targeted level N times and lets AIPerf produce its own aggregate
  directory with mean / std / confidence intervals.
- **`AIPERF_SWEEP_NATIVE_PASSTHROUGH=true`** — for a pure single-axis parameter
  sweep with **no** cache-hit targeting, hands the whole thing to native AIPerf
  (its own `sweep_aggregate/` with best-config and Pareto analysis). Provide the
  axis via `AIPERF_EXTRA_ARGS`, e.g. `--concurrency 10,20,50,100`. This bypasses
  cache reset and Prometheus verification — use only when you want a plain
  parameter sweep, not a controlled KV-cache-hit-rate sweep.

## Deployment: Single Machine

```bash
docker compose up
```

## Deployment: Split Across Two Machines

Server on Machine A (SUT), client on Machine B (load generator).

**Machine A:**
```bash
docker compose up lmcache-server-gpu
# Verify: curl http://localhost:30080/v1/models
```

**Machine B:**
```bash
AIPERF_SERVER_URL=http://<machine-a-ip>:30080 \
  docker compose -f docker-compose.yml -f docker-compose.client-only.yml \
  up aiperf-client
```

Machine A must expose port 30080 (and, for the sweep's GPU metrics, the DCGM
port 9400). Remote backends only need to be reachable from Machine A. For sweeps,
point `AIPERF_SWEEP_METRICS_URL` and `AIPERF_SWEEP_GPU_METRICS_URL` at Machine A.

## Output

```
results/
├── aiperf-<suite>_report.html       # CMS HTML report
├── results_aiperf_<suite>.json      # Normalized JSON (+ sweep_summary, native_sweep_aggregate)
├── results_aiperf_<suite>.csv       # Normalized CSV (+ sweep columns when sweeping)
├── sysinfo/                         # Hardware/software BOM
├── config/                          # Reproducibility artifacts
│   └── lmcache_backend_info.json    # Backend + sweep metadata
├── aiperf_results/                  # Raw AIPerf output
│   └── <model>-<endpoint>-<mode>N/
│       ├── profile_export_aiperf.json
│       ├── profile_export_aiperf.csv
│       └── profile_export.jsonl
├── sweep_results/                   # Present only when AIPERF_SWEEP_ENABLED=true
│   ├── sweep_summary.csv            # One row per level: target vs measured hit %, GPU util
│   ├── dry_run_commands.txt         # Present only on a dry run
│   └── hit_<N>pct/
│       ├── sweep_level_info.json    # Per-level params + measured rates
│       ├── metrics_timeseries.csv   # GPU-util samples during the level
│       ├── aiperf_stdout.log
│       └── artifacts/               # AIPerf's own per-level output
└── container_results.tar.gz         # Complete archive
```

When sweeping, the normalized CSV gains these columns: `Target Cache Hit %`,
`Actual Cache Hit % (external/Maru)`, `vLLM L1 Cache Hit %`, `GPU Util %`, and the
sweep parameter columns.

## Troubleshooting

**Maru healthcheck fails with `Servname not supported` / `Invalid argument`
mentioning a stray `}`:**
The stock healthcheck used an unescaped `${LMCACHE_MARU_PORT:-5555}` inside the
compose `test:` array; depending on parsing, the closing brace can leak into the
`/dev/tcp` target, so the probe tries to connect to a host literally named
`5555}`. Hardcode the port in the maru healthcheck:
```yaml
healthcheck:
  test: ["CMD", "bash", "-c", "echo > /dev/tcp/127.0.0.1/5555"]
```
Verify the metadata port is actually up:
`docker exec ocp-cms-aiperf-maru bash -c "echo > /dev/tcp/127.0.0.1/5555 && echo OK"`.

**Server crashes at startup with `FileNotFoundError: .../lmcache_prometheus/...`:**
`PROMETHEUS_MULTIPROC_DIR` points at a directory that does not exist. The
`server-entrypoint.sh` creates it clean before launch; if you customized the
entrypoint, ensure it does `rm -rf` then `mkdir -p` on that path before
`vllm serve`.

**Sweep "Actual Cache Hit %" is N/A:**
The client could not read the cache counters. Confirm the metrics exist:
`curl -s localhost:30080/metrics | grep -E 'external_prefix_cache|lmcache:'`.
If they are absent, `PROMETHEUS_MULTIPROC_DIR` is not set up (see above). If the
endpoint itself is unreachable, check `AIPERF_SWEEP_METRICS_URL`.

**Sweep "GPU Util %" is N/A:**
The DCGM exporter is unreachable or not exporting utilization. Confirm:
`curl -s localhost:9400/metrics | grep DCGM_FI_DEV_GPU_UTIL`. If the container is
not up, check `docker logs ocp-cms-aiperf-dcgm`. A common cause is a driver/DCGM
version mismatch — match the `dcgm-exporter` image tag in `docker-compose.yml` to
your driver (`nvidia-smi --query-gpu=driver_version --format=csv,noheader`). If
the metric is absent but the container is up, the custom `dcgm-metrics.csv` did
not mount — it must sit next to `docker-compose.yml`.

**Per-level cache reset does nothing / levels contaminate each other:**
`/reset_prefix_cache` only exists when `VLLM_SERVER_DEV_MODE=1`. Without it the
reset call 404s. Set it on the server. The sweep still reports per-level rates
from counter deltas, but levels no longer start cold.

**`VLLM_GPU_MEMORY_UTILIZATION` / `VLLM_MAX_MODEL_LEN` "Unknown vLLM environment
variable" warnings:**
Harmless. The entrypoint reads these env vars and converts them into the
`--gpu-memory-utilization` / `--max-model-len` CLI flags, which vLLM does honor.
vLLM separately warns about any unknown `VLLM_*` env var it sees; it ignores the
env var and uses the flag.

**"No /dev/dax* devices found" / "No such device or address: /dev/daxN.N":**
DAX devices not mapped. Add `devices:` entries to `docker-compose.yml` for both
`maru` and `lmcache-server-gpu`. Run `ls /dev/dax*` on the host.

**Healthcheck timeout / "dependency failed to start":**
vLLM takes minutes to load large models. The server healthcheck has a long start
period. Watch `docker compose logs lmcache-server-gpu -f`. If maru is the
unhealthy dependency, see the maru healthcheck note above —
`docker inspect --format '{{json .State.Health}}' ocp-cms-aiperf-maru` shows the
actual failing probe output.

**HuggingFace 401/403 errors:**
401 = token not passed; check `HF_TOKEN`. 403 = token works but you have not
accepted the model license on the HuggingFace model page.

**No AIPerf results found by parser:**
AIPerf creates a subdirectory per run under `aiperf_results/`. The parser searches
recursively for `profile_export_aiperf.json`. For sweeps it also reads each
`hit_<N>pct/sweep_level_info.json`.

## EDITME.env Variable Reference

Copy `EDITME.env` to `.env` and edit. Variables shown commented in `EDITME.env`
are optional and fall back to the default listed here.

### Core

| Variable | Default | Description |
|---|---|---|
| `HOST_RESULTS_DIR` | `./results` | Host directory mounted into the client for all output. |
| `HF_TOKEN` | _(empty)_ | HuggingFace token. Required for gated models; you must also accept the license on the model page. |

### Model & GPU

| Variable | Default | Description |
|---|---|---|
| `AIPERF_MODEL` | `meta-llama/Llama-3.1-8B-Instruct` | HuggingFace model the server loads and the client benchmarks. |
| `VLLM_MAX_MODEL_LEN` | `4096` | Max sequence length passed to vLLM (`--max-model-len`). |
| `CUDA_VISIBLE_DEVICES` | `0` | Which GPU(s) the server uses. |
| `VLLM_GPU_MEMORY_UTILIZATION` | `0.8` | Fraction of GPU memory vLLM may use (`--gpu-memory-utilization`). Higher = larger GPU-resident KV cache. |

### LMCache backend

| Variable | Default | Description |
|---|---|---|
| `LMCACHE_BACKEND` | `cpu_offload` | Selects the KV cache backend. See the backend table above. |
| `LMCACHE_REMOTE_HOST` | _(unset)_ | Host for `redis` / `lmserver` / `mooncake` / `infinistore`. |
| `LMCACHE_REMOTE_PORT` | _(unset)_ | Port for the remote backend. |
| `LMCACHE_MARU_HOST` | `localhost` | Maru metadata server host. |
| `LMCACHE_MARU_PORT` | `5555` | Maru metadata server port. |
| `LMCACHE_MARU_POOL_SIZE` | `4` | Size of the Maru CXL KV pool, in GiB. Set to the CXL capacity you want to exercise (e.g. `200`). |
| `LMCACHE_MOONCAKE_METADATA_SERVER` | _(unset)_ | Mooncake metadata server URL. |
| `LMCACHE_MOONCAKE_PROTOCOL` | _(unset)_ | Mooncake transport protocol (e.g. `tcp`). |
| `LMCACHE_INFINISTORE_DEVICE` | _(unset)_ | InfiniStore RDMA device (e.g. `mlx5_1`). |
| `LMCACHE_CONFIG_FILE_CONTENT` | _(unset)_ | Base64-encoded LMCache YAML for `LMCACHE_BACKEND=custom`. |

### Maru container tuning

| Variable | Default | Description |
|---|---|---|
| `MARU_GIT_REF` | `main` | Git ref of Maru to build into the maru image. |
| `MARU_RM_HOST` | `127.0.0.1` | Resource-manager bind/connect host. |
| `MARU_RM_PORT` | `9850` | Resource-manager port. Change per stack when running multiple Maru instances on one host. |
| `MARU_SERVER_HOST` | `0.0.0.0` | Metadata-server bind host. |
| `MARU_LOG_LEVEL` | `INFO` | Maru log verbosity. |

### Deployment

| Variable | Default | Description |
|---|---|---|
| `AIPERF_SERVER_URL` | _(auto)_ | Override the server URL the client targets. Set on the client machine for split-machine runs. |

### AIPerf benchmark (single-run)

| Variable | Default | Description |
|---|---|---|
| `AIPERF_SUITE_NAME` | `ocp-cms-aiperf` | Suite name used in output filenames. |
| `AIPERF_ENDPOINT_TYPE` | `chat` | AIPerf endpoint type (e.g. `chat`, `completions`). |
| `AIPERF_STREAMING` | `true` | Use streaming responses (`--streaming`). |
| `AIPERF_CONCURRENCY` | `10` | Concurrent virtual users (concurrency mode). |
| `AIPERF_REQUEST_COUNT` | `100` | Total requests to send. |
| `AIPERF_REQUEST_RATE` | _(unset)_ | If set, use request-rate mode (requests/sec) instead of concurrency. |
| `AIPERF_ISL` | _(unset)_ | Synthetic input sequence length (tokens). Maps to `--synthetic-input-tokens-mean`. |
| `AIPERF_OSL` | _(unset)_ | Synthetic output sequence length (tokens). Maps to `--output-tokens-mean`. |
| `AIPERF_WARMUP_REQUEST_COUNT` | `5` | Warmup requests before measurement. |
| `AIPERF_TOKENIZER` | _(auto)_ | Tokenizer override; auto-detected from the model if unset. |
| `AIPERF_NUM_PROFILE_RUNS` | `1` | Repeat the run N times for confidence intervals (single-run mode). |
| `AIPERF_PUBLIC_DATASET` | _(unset)_ | Use a public dataset, e.g. `sharegpt`. |
| `AIPERF_INPUT_FILE` | _(unset)_ | Path to a custom trace file. |
| `AIPERF_CUSTOM_DATASET_TYPE` | _(unset)_ | Custom dataset type, e.g. `mooncake_trace`. |
| `AIPERF_FIXED_SCHEDULE` | `false` | Replay a trace on its original schedule (`--fixed-schedule`). |
| `AIPERF_GOODPUT_TTFT` | _(unset)_ | Goodput SLO: max acceptable TTFT in ms. |
| `AIPERF_GOODPUT_LATENCY` | _(unset)_ | Goodput SLO: max acceptable request latency in ms. |
| `AIPERF_EXTRA_ARGS` | _(unset)_ | Raw args appended to `aiperf profile`. Also supplies the axis for native passthrough sweeps. |

### KV cache parameter sweep

| Variable | Default | Description |
|---|---|---|
| `AIPERF_SWEEP_ENABLED` | `false` | Master switch. When `true`, the single-run benchmark is replaced by the sweep. |
| `AIPERF_SWEEP_LEVELS` | `95,90,85,80,75,50,25,15,10,5` | Target hit-rate percentages to run. A subset (e.g. `95,50,5`) uses the matching default bundles. |
| `AIPERF_SWEEP_TURN_MEAN` | _(per-level default)_ | Override: mean conversation turns per level, aligned to `AIPERF_SWEEP_LEVELS`. |
| `AIPERF_SWEEP_TURN_STDDEV` | _(per-level default)_ | Override: stddev of turn count per level. |
| `AIPERF_SWEEP_TURN_DELAY_MS` | _(per-level default)_ | Override: mean delay between turns (ms) per level. |
| `AIPERF_SWEEP_ISL` | _(per-level default)_ | Override: input tokens per level. |
| `AIPERF_SWEEP_OSL` | _(per-level default)_ | Override: output tokens per level. |
| `AIPERF_SWEEP_CONCURRENCY` | _(per-level default)_ | Override: concurrency per level. |
| `AIPERF_SWEEP_SHARED_PROMPT` | _(per-level default)_ | Override: shared system-prompt length (tokens) per level — the main lever for prefix-cache hits. |
| `AIPERF_SWEEP_CONV_NUM` | _(per-level default)_ | Override: number of conversations per level. |
| `AIPERF_SWEEP_DATASET_ENTRIES` | _(per-level default)_ | Override: unique prompts in the dataset per level. |
| `AIPERF_SWEEP_COOLDOWN` | `30` | Seconds to wait between levels (lets the cache/backend quiesce after reset). |
| `AIPERF_SWEEP_DURATION` | _(unset)_ | Per-level benchmark duration (seconds). When unset, a level runs until its conversation/request count is exhausted. Set a floor for stable low-hit-rate measurements. |
| `AIPERF_SWEEP_METRICS_INTERVAL` | `5` | Seconds between GPU-util samples within a level. |
| `AIPERF_SWEEP_SKIP_LEVELS` | _(empty)_ | Comma-separated hit% levels to skip (e.g. `75,50`). |
| `AIPERF_SWEEP_DRY_RUN` | `false` | Log each level's `aiperf` command (to `dry_run_commands.txt`) without executing. |
| `AIPERF_SWEEP_METRICS_URL` | `http://localhost:30080/metrics` | Where the client scrapes cache-hit counters (vLLM `/metrics`). |
| `AIPERF_SWEEP_GPU_UTIL_FLOOR` | `75` | Logs a warning when measured GPU util drops below this percentage. |
| `AIPERF_SWEEP_GPU_METRICS_URL` | `http://localhost:9400/metrics` | Where the client scrapes GPU util (DCGM exporter). Falls back to `nvidia-smi`. |
| `AIPERF_SWEEP_CONNECTION_STRATEGY` | `sticky-user-sessions` | AIPerf connection strategy for multi-turn levels, so a conversation's turns hit the same worker. |
| `AIPERF_SWEEP_NUM_PROFILE_RUNS` | `1` | Native confidence aggregation: runs each targeted level N times. |
| `AIPERF_SWEEP_PARAM_SWEEP_MODE` | `repeated` | AIPerf sweep mode for native aggregation: `repeated` or `independent`. |
| `AIPERF_SWEEP_NATIVE_PASSTHROUGH` | `false` | Hand a pure single-axis sweep to native AIPerf (no cache-hit targeting). Axis comes from `AIPERF_EXTRA_ARGS`. |

### Advanced

| Variable | Default | Description |
|---|---|---|
| `AIPERF_VERSION` | `main` | AIPerf version/ref built into the client image. |
| `EXTRA_PIP_PACKAGES` | _(unset)_ | Extra pip packages to install into the client image. |
| `CMS_VERBOSITY` | `0` | CMS reporting verbosity. |

### Server-side variables (not in EDITME.env, set by `server-entrypoint.sh`)

These are required for the sweep and are configured by the server entrypoint; set
them explicitly only if you customize the entrypoint or the compose environment.

| Variable | Purpose |
|---|---|
| `VLLM_SERVER_DEV_MODE=1` | Exposes `POST /reset_prefix_cache` (needed for per-level cache reset). |
| `PROMETHEUS_MULTIPROC_DIR` | Shared dir so vLLM + LMCache (separate processes) both export metrics. Must exist and be clean at launch. |

## File Inventory

```
aiperf/
├── EDITME.env                       # All configuration — copy to .env
├── Dockerfile.maru                  # Maru: resource manager + metadata server
├── Dockerfile.server                # Server: vLLM + LMCache + Maru client (GPU)
├── Dockerfile.client                # Client: AIPerf + CMS reporting
├── docker-compose.yml               # Orchestration — Maru-backend example (server, client, dcgm, maru)
├── docker-compose.client-only.yml   # Split-machine override
├── dcgm-metrics.csv                 # DCGM custom metric set (enables GPU_UTIL)
├── maru-entrypoint.sh               # Maru startup (RM + metadata server)
├── server-entrypoint.sh             # LMCache config, multiproc-metrics + dev-mode setup, vLLM launch
├── client-entrypoint.sh             # Server wait, single-run OR sweep, reporting
├── parse_results.py                 # Normalizes results → CMS JSON/CSV (incl. sweep columns)
├── configs/                         # Pre-baked LMCache backend configs
│   ├── cpu_offload.yaml
│   ├── disk.yaml
│   ├── redis.yaml
│   ├── lmserver.yaml
│   ├── mooncake.yaml
│   ├── infinistore.yaml
│   └── maru.yaml
├── examples/                        # Ready-to-use .env files
│   ├── maru.env
│   ├── maru-highload.env
│   └── maru-sharegpt.env
└── README.md
```

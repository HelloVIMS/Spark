# Spark

Resource guardrails for running multiple vLLM servers on unified-memory
machines — NVIDIA DGX Spark / GB10, AMD Strix Halo, Apple Silicon — plus
plain discrete-GPU boxes.

## The problem

On a Grace-Blackwell GB10 there is **no discrete VRAM**.
`nvidia-smi --query-gpu=memory.total` returns `[N/A]` because the CPU and
GPU share one 121–128GB pool. That changes what
`--gpu-memory-utilization` means: it is not "a share of spare VRAM the
host will never miss" — it is a share of **total system RAM**, reserved
up front, taken from the same pool your desktop, IDE, browser and
daemons draw from.

Each service picks its fraction independently, and nothing adds them up.
A real configuration that shipped:

| service         | `--gpu-memory-utilization` | cumulative |
|-----------------|---------------------------|------------|
| embeddings      | 0.10 (always on)          | 0.10       |
| gemma4          | 0.65                      | 0.75 = 91GB / 122GB |
| vision-agent    | 0.75                      | 0.85 = 104GB |
| longcontext     | 0.95                      | **1.05 — more RAM than the machine has** |

At 1.05 the services cannot coexist, so the kernel OOM killer resolves
the contradiction — and its victim is as likely to be your desktop or a
daemon as it is to be vLLM. That's the crash: not a vLLM bug, just an
impossible sum nobody was checking.

## What this repo installs

**Memory budget guard** (`scripts/vllm_mem_budget.sh`) — before each
vLLM server starts, sums the `--gpu-memory-utilization` of every vLLM
already running and *refuses to start* if the total would exceed
`VLLM_MEM_BUDGET` (default 0.80). Loud, informative failure instead of
a silent OOM:

```
FATAL: longcontext wants --gpu-memory-utilization 0.95, which would
       take the GPU-memory total to 1.05, over the 0.80 budget.

       Each fraction is a share of TOTAL SYSTEM RAM (unified memory),
       not free headroom. Already reserved (0.10):
  pid 8123 port 8001 at 0.10
```

On discrete-VRAM GPUs the same check applies against VRAM — the guard
auto-detects which pool the fractions sum against.

**CPU isolation** (`scripts/vllm_env.sh`) — `taskset` pins each vLLM to
`VLLM_CPU_SHARE` of cores (default 80%), reserving the rest for the
desktop, IDE and daemons. Under full inference load the machine stays
interactive.

**Guarded launcher** (`scripts/vllm-serve.sh`) — thin wrapper that
sources site config, applies the env defaults that proved stable under
parallel desktop load (`VLLM_USE_V1=0`, `CUDA_LAUNCH_BLOCKING=1`, single
compile job, …), enforces both guards, and `exec`s `vllm serve`. Extra
CLI args pass straight through.

**systemd user units** — `vllm-embeddings` (always-on, 0.10),
`vllm-longcontext` and `vllm-vision-agent` (mutually exclusive on port
8000, marked `Conflicts=`), and a `vllm-model@<name>` template that runs
any spec dropped in `~/.config/spark/models/<name>.env`.

**Cgroup caps example** (`examples/vims-server-memcap.conf`) — a drop-in
showing how `MemoryHigh`/`MemoryMax` contain a daemon whose subprocesses
can balloon (ours hit 33GB archiving documents), so the cgroup OOM
killer targets the culprit inside the unit instead of a random system
process.

**sysctl tuning** (`sysctl/99-spark.conf`) — larger socket buffers and
a bigger inotify cap; optional, applied only with `--sysctl`.

## Install

```bash
git clone https://github.com/hellovims/spark
cd spark
./install.sh                  # user-level: launchers, units, config
sudo ./install.sh --sysctl    # optionally apply /etc/sysctl.d/99-spark.conf
```

Nothing starts automatically — the install is safe on a live box.

## Configure

Edit `~/.config/spark/spark.conf`:

```bash
MODELS_DIR="$HOME/models"     # where relative VLLM_MODEL names resolve
VLLM_BIN="$HOME/venv/bin/vllm"  # pin your venv — strongly recommended
VLLM_MEM_BUDGET="0.80"        # ceiling on summed gpu-memory-utilization
VLLM_CPU_SHARE="0.80"         # core fraction pinned to each vLLM
```

Budget guidance (unified memory):

| total | use case |
|-------|----------|
| 0.55  | headroom for browser/Electron test runs |
| 0.65  | normal desktop development |
| 0.80  | inference-heavy; expect swap under desktop load |

## Run

```bash
systemctl --user enable --now vllm-embeddings   # the always-on one
systemctl --user start vllm-longcontext       # or:
run-model.sh vllm-vision-agent                # switches port-8000 models
```

Or define your own model without writing a unit:

```bash
# ~/.config/spark/models/mymodel.env
VLLM_MODEL=my-model-dir
VLLM_PORT=8000
VLLM_GPU_MEM_UTIL=0.70
VLLM_EXTRA_ARGS=--dtype bfloat16 --max-model-len 65536
```

```bash
systemctl --user start vllm-model@mymodel
```

## Retune without editing files

Per-service fractions are env vars, so a temporary change is a systemd
drop-in — reverted by deleting one file:

```bash
systemctl --user edit vllm-longcontext
```

```ini
[Service]
Environment=VLLM_GPU_MEM_UTIL=0.75
```

## Design notes

- **Fail loud at launch, not at 3am.** The budget check runs before
  `exec`, so a misconfigured sum exits in milliseconds with an
  explanation, instead of taking out the desktop hours later.
- **Percentages, not absolutes.** `VLLM_MEM_BUDGET`, `VLLM_CPU_SHARE`
  and cgroup `MemoryMax` all derive from the machine's own RAM and core
  count — the same units work on a 64GB laptop, a 121GB GB10, or a
  multi-GPU server. Auto-detection (`nvidia-smi` returning `[N/A]` for
  memory) decides whether the budget means system RAM or VRAM.
- **Everything overridable by env + drop-ins.** No tunable lives only
  inside a script; a test run can raise a limit and have it revert
  cleanly afterward.

## Layout

```
install.sh
config/spark.conf          -> ~/.config/spark/spark.conf
config/models/*.env        -> ~/.config/spark/models/   (vllm-model@ specs)
scripts/vllm_env.sh            CPU isolation
scripts/vllm_mem_budget.sh     memory budget guard
scripts/vllm-serve.sh          guarded launcher
scripts/run-model.sh           port-8000 model switcher
systemd/user/*.service     -> ~/.config/systemd/user/
sysctl/99-spark.conf       -> /etc/sysctl.d/  (only with --sysctl)
examples/vims-server-memcap.conf   cgroup cap drop-in example
```

## License

See [LICENSE](LICENSE).

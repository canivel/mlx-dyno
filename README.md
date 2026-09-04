# MLX Station

One app for running local LLMs on Apple Silicon and seeing exactly what they are
doing — model throughput and machine telemetry in the same place, because on a
Mac they are the same story: tokens per second is set by memory bandwidth, and
memory bandwidth is set by how the model fits.

Three pieces, in one repository:

| | What it is |
|---|---|
| **MLX Station.app** | Menu bar app. Runs models, shows their metrics and the machine's. |
| **`mlxserve`** | MLX inference server that reports its own throughput over `/metrics` and `/stats`. |
| **`gpumon`** | Terminal dashboard for the hardware metrics alone, with JSON and CSV output. |

## Why this exists

`llama.cpp` and vLLM both expose Prometheus metrics, so anything watching them
knows the real tokens/sec. On Apple Silicon the fast path is MLX, and
`mlx_lm.server` measures throughput internally but never exposes it — so a
monitor has to guess from the outside.

`mlxserve` closes that gap. It is **not a fork**: it imports `mlx_lm.server`,
swaps two classes for instrumented subclasses, and hands control back. Every
existing flag keeps working, and so do mlx_lm's batching, prompt caching and
speculative decoding. The additions are timing hooks inside the token stream and
two endpoints.

## Install

Requires macOS on Apple Silicon and Xcode's Swift toolchain.

```sh
git clone git@github.com:canivel/macos-gpu-llm-monitor.git
cd macos-gpu-llm-monitor

# the server
uv venv ~/.mlxserve/venv
uv pip install --python ~/.mlxserve/venv/bin/python ./server

# the app
cd app && ./build.sh
cp -r "build/MLX Station.app" /Applications/
open "/Applications/MLX Station.app"
```

The app looks for `mlxserve` at `~/.mlxserve/venv/bin/mlxserve`, then on `PATH`,
so that install location needs no configuration. It is menu-bar only — no Dock
icon, no window.

## Running a model

Click the menu bar icon, pick a model, press **Start**. Models are found in the
Hugging Face cache, the LM Studio cache and `~/models`; add your own folder
under Settings. The app supervises the server and stops it when you quit, so a
model is never left holding tens of gigabytes.

Or run it yourself:

```sh
mlxserve --model mlx-community/Qwen3-8B-4bit --port 8971
```

```
mlxserve 0.1.0  ·  MLX inference with exportable metrics
  OpenAI API   http://127.0.0.1:8971/v1
  Metrics      http://127.0.0.1:8971/metrics   (Prometheus)
  Stats        http://127.0.0.1:8971/stats     (JSON)
```

Either way the app finds it, because it discovers servers by looking up the TCP
ports each LLM process is listening on — no default-port assumptions.

## The metrics

Everything is measured inside the generation loop, so nothing is inferred:

| Metric | Meaning |
|---|---|
| `mlx:decode_tokens_per_second` | In-flight throughput; falls back to recent history when idle |
| `mlx:live_decode_tokens_per_second` | Requests generating right now, summed |
| `mlx:last_time_to_first_token_seconds` | Prompt processing plus queue wait |
| `mlx:last_prompt_tokens_per_second` | Prefill throughput |
| `mlx:cached_prompt_tokens_total` | Prompt tokens the cache served |
| `mlx:tokens_generated_total`, `mlx:prompt_tokens_total` | Cumulative counters |
| `mlx:requests_active`, `mlx:requests_total`, `mlx:requests_failed_total` | Request state |
| `mlx:memory_active_bytes`, `_peak_bytes`, `_cache_bytes` | MLX allocator |
| `mlx:model_load_seconds`, `mlx:uptime_seconds` | Server state |

The decode rate deliberately excludes prompt processing and queue time: it is
tokens produced divided by the time spent producing them, which is the number
that answers "how fast does this model generate". Verified against wall-clock
timing — a request that took 5.46 s end to end with 0.36 s to first token
reported 31.2 tok/s, exactly `159 ÷ 5.10`.

`/stats` returns the same figures as JSON, plus the last ten requests
individually (queue wait, TTFT, prefill rate, decode rate, cache hits,
finish reason).

## Other runtimes

The app is not MLX-only. It also reads:

- **llama.cpp** — `/props` for the model, `/metrics` for measured throughput
  (start it with `--metrics`)
- **vLLM** — `/metrics`
- **Ollama** — `/api/ps` for resident models and their VRAM
- **LM Studio** and anything OpenAI-compatible — `/v1/models`

For a runtime that reports no throughput, the app estimates it from memory
bandwidth: generating a token re-reads the whole weight set, so read bandwidth ÷
model size is the decode rate. Measured against a 27B 8-bit model on an M5 Max,
`244 GB/s ÷ 27.2 GB = 8.97` predicted against **8.70 tok/s measured — within
3%**. That holds only while the model has the GPU to itself; under a second
concurrent workload the same model measured 8.73 while the estimate said ~10.3.
Estimates are always marked `≈ est.`, and the app shows `—` rather than a number
whenever more than one model is loaded and bandwidth cannot be attributed.

## Machine metrics

No `sudo`, ever. Most Apple Silicon monitors shell out to `powermetrics`, which
needs root; this reads the same counters one level down through `IOReport`,
IOKit and Metal, all readable by a normal user.

- **GPU** busy percentage from P-state residency, and the clock averaged over
  busy time only — a GPU pinned at 100% on a low clock is power- or
  thermally-limited, not working hard.
- **GPU memory** against Metal's `recommendedMaxWorkingSetSize`, the real
  ceiling for weights plus KV cache (107.5 GB on a 128 GB Mac). Cross it and
  allocations spill to CPU memory and throughput collapses.
- **Memory bandwidth**, estimated from the controller's histogram — quantised to
  the bucket width, and labelled as an estimate.
- **Power** for the GPU, CPU, DRAM and Neural Engine rails separately, the SoC
  total, and wall draw against the adapter's rating.

`Device Utilization %` from the IOKit accelerator node, which several other
tools report as GPU usage, is unreliable on recent macOS — it reads near 100% on
an idle machine. This ignores it in favour of P-state residency.

## The terminal tool

```sh
uv venv && uv pip install -e .
.venv/bin/gpumon                       # live dashboard
.venv/bin/gpumon --once                # one snapshot
.venv/bin/gpumon --json                # newline-delimited JSON
.venv/bin/gpumon --csv run.csv -i 0.5  # log a benchmark run
```

Hardware metrics only; model detection lives in the app.

## Layout

```
server/            mlxserve — the instrumented MLX server
app/               MLX Station.app
  Sources/MLXStationKit/   IOReport, IOKit, libproc, Metal, model + server discovery
  Sources/MLXStation/      SwiftUI menu bar app
  Sources/probe/           command-line harness for the metrics layer
  build.sh                 compiles and assembles the .app
src/gpumon/        the Python CLI
```

`app/.build/release/probe` prints the Swift layer's raw readings, which is the
quickest way to check what the app is seeing.

## Compatibility

`mlxserve` needs `mlx-lm >= 0.28` and hooks three internals of
`mlx_lm.server` (`ResponseGenerator`, `_run_http_server`, `ModelProvider.load`).
Those are checked at start-up: if a future mlx_lm reshapes them it fails loudly
rather than serving without metrics.

## License

MIT

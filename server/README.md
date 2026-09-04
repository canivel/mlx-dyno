# mlxserve

An MLX inference server for Apple Silicon that reports what it is actually
doing: tokens per second, time to first token, queue wait and prompt-cache
hits, over a Prometheus `/metrics` endpoint and a JSON `/stats` endpoint.

`mlx_lm.server` already measures throughput internally -- it just never exposes
it, so anything watching from outside has to guess. `mlxserve` is not a fork:
it imports `mlx_lm.server`, replaces two classes with instrumented subclasses,
and hands control straight back. Every existing flag keeps working, batching
and prompt caching included.

```sh
mlxserve --model mlx-community/Qwen3-8B-4bit --port 1234
```

```
mlxserve 0.1.0  ·  MLX inference with exportable metrics
  OpenAI API   http://127.0.0.1:1234/v1
  Metrics      http://127.0.0.1:1234/metrics   (Prometheus)
  Stats        http://127.0.0.1:1234/stats     (JSON)
```

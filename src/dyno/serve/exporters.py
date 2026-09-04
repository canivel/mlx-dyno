"""Metric output formats: Prometheus text for scrapers, JSON for the UI."""

from __future__ import annotations

import json
from typing import Any

from .metrics import MetricsRegistry

PROMETHEUS_CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"


def _mlx_memory() -> dict[str, int]:
    """Live allocator figures from MLX, if it is importable."""
    try:
        import mlx.core as mx
    except Exception:
        return {}
    readings: dict[str, int] = {}
    for key, getter in (
        ("active_bytes", "get_active_memory"),
        ("peak_bytes", "get_peak_memory"),
        ("cache_bytes", "get_cache_memory"),
    ):
        function = getattr(mx, getter, None)
        if function is None:
            continue
        try:
            readings[key] = int(function())
        except Exception:
            continue
    return readings


def _line(name: str, value: float | int | None, help_text: str, kind: str) -> list[str]:
    if value is None:
        return []
    return [f"# HELP {name} {help_text}", f"# TYPE {name} {kind}", f"{name} {value}"]


def prometheus_text(registry: MetricsRegistry) -> str:
    """Prometheus exposition format.

    Names follow the `mlx:` convention used by llama.cpp and vLLM so existing
    scrapers and dashboards need no special casing.
    """
    last = registry.last_completed()
    memory = _mlx_memory()
    # Prefer what is happening now; fall back to recent history when idle.
    rolling = registry.live_decode_rate() or registry.rolling_decode_rate()

    lines: list[str] = []
    lines += _line("mlx:requests_total", registry.requests_total,
                   "Completed generation requests.", "counter")
    lines += _line("mlx:requests_failed_total", registry.requests_failed,
                   "Generation requests that ended in an error.", "counter")
    lines += _line("mlx:requests_active", registry.active_requests,
                   "Requests generating or queued right now.", "gauge")
    lines += _line("mlx:prompt_tokens_total", registry.prompt_tokens_total,
                   "Prompt tokens processed.", "counter")
    lines += _line("mlx:cached_prompt_tokens_total", registry.cached_prompt_tokens_total,
                   "Prompt tokens served from the prompt cache.", "counter")
    lines += _line("mlx:tokens_generated_total", registry.completion_tokens_total,
                   "Tokens generated.", "counter")
    lines += _line("mlx:decode_seconds_total", round(registry.decode_seconds_total, 4),
                   "Wall seconds spent in the decode phase.", "counter")
    lines += _line("mlx:decode_tokens_per_second", _round(rolling),
                   "Decode throughput: in-flight requests if any, else recent history.",
                   "gauge")
    lines += _line("mlx:live_decode_tokens_per_second", _round(registry.live_decode_rate()),
                   "Decode throughput of requests generating right now.", "gauge")

    if last is not None:
        lines += _line("mlx:last_decode_tokens_per_second",
                       _round(last.decode_tokens_per_second),
                       "Decode throughput of the most recent request.", "gauge")
        lines += _line("mlx:last_prompt_tokens_per_second",
                       _round(last.prompt_tokens_per_second),
                       "Prompt processing throughput of the most recent request.", "gauge")
        lines += _line("mlx:last_time_to_first_token_seconds",
                       _round(last.time_to_first_token),
                       "Time to first token of the most recent request.", "gauge")
        lines += _line("mlx:last_queue_seconds", _round(last.queue_seconds),
                       "Queue wait of the most recent request.", "gauge")

    for key, value in memory.items():
        lines += _line(f"mlx:memory_{key}", value, f"MLX allocator {key}.", "gauge")

    lines += _line("mlx:model_load_seconds", _round(registry.model_load_seconds),
                   "Seconds taken to load the current model.", "gauge")
    lines += _line("mlx:uptime_seconds", round(registry.uptime_seconds(), 2),
                   "Server uptime.", "gauge")
    return "\n".join(lines) + "\n"


def stats_json(registry: MetricsRegistry, model_path: str | None = None) -> str:
    """Richer JSON for a UI: everything Prometheus has, plus request history."""
    last = registry.last_completed()
    payload: dict[str, Any] = {
        "model": {
            "name": registry.model_name,
            "path": model_path,
            "loaded_at": registry.model_loaded_at,
            "load_seconds": _round(registry.model_load_seconds),
        },
        "live": {
            "requests_active": registry.active_requests,
            "decode_tokens_per_second":
                _round(registry.live_decode_rate() or registry.rolling_decode_rate()),
            "live_decode_tokens_per_second": _round(registry.live_decode_rate()),
            "rolling_decode_tokens_per_second": _round(registry.rolling_decode_rate()),
            "last_decode_tokens_per_second":
                _round(last.decode_tokens_per_second) if last else None,
            "last_prompt_tokens_per_second":
                _round(last.prompt_tokens_per_second) if last else None,
            "last_time_to_first_token": _round(last.time_to_first_token) if last else None,
        },
        "totals": {
            "requests": registry.requests_total,
            "requests_failed": registry.requests_failed,
            "prompt_tokens": registry.prompt_tokens_total,
            "cached_prompt_tokens": registry.cached_prompt_tokens_total,
            "generated_tokens": registry.completion_tokens_total,
            "decode_seconds": round(registry.decode_seconds_total, 4),
        },
        "memory": _mlx_memory(),
        "uptime_seconds": round(registry.uptime_seconds(), 2),
        "recent_requests": [record.to_dict() for record in registry.recent(10)],
    }
    return json.dumps(payload, indent=2)


def _round(value: float | None, digits: int = 3) -> float | None:
    return None if value is None else round(value, digits)

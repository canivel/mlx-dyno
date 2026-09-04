"""Metrics registry.

Everything here is measured inside the generation loop rather than inferred
from the outside, so the numbers are the real ones: time to first token is the
gap until the first token is actually yielded, and decode rate counts only the
decode phase, not prompt processing or queue time.
"""

from __future__ import annotations

import threading
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any


@dataclass
class RequestRecord:
    """One generation request, timed from submission to completion."""

    request_id: int
    model: str
    submitted_at: float
    started_at: float | None = None
    first_token_at: float | None = None
    finished_at: float | None = None
    prompt_tokens: int = 0
    cached_prompt_tokens: int = 0
    completion_tokens: int = 0
    finish_reason: str | None = None
    failed: bool = False

    @property
    def queue_seconds(self) -> float | None:
        if self.started_at is None:
            return None
        return self.started_at - self.submitted_at

    @property
    def time_to_first_token(self) -> float | None:
        if self.first_token_at is None:
            return None
        return self.first_token_at - self.submitted_at

    @property
    def decode_seconds(self) -> float | None:
        """Wall time spent generating, excluding prompt processing and queueing."""
        if self.first_token_at is None or self.finished_at is None:
            return None
        return max(self.finished_at - self.first_token_at, 1e-9)

    @property
    def decode_tokens_per_second(self) -> float | None:
        seconds = self.decode_seconds
        if seconds is None or self.completion_tokens <= 1:
            return None
        # The first token is already emitted at first_token_at, so the tokens
        # produced during the decode window are one fewer.
        return (self.completion_tokens - 1) / seconds

    @property
    def prompt_tokens_per_second(self) -> float | None:
        if self.first_token_at is None or self.started_at is None:
            return None
        elapsed = self.first_token_at - self.started_at
        if elapsed <= 0 or self.prompt_tokens <= 0:
            return None
        return self.prompt_tokens / elapsed

    @property
    def total_seconds(self) -> float | None:
        if self.finished_at is None:
            return None
        return self.finished_at - self.submitted_at

    def to_dict(self) -> dict[str, Any]:
        return {
            "request_id": self.request_id,
            "model": self.model,
            "prompt_tokens": self.prompt_tokens,
            "cached_prompt_tokens": self.cached_prompt_tokens,
            "completion_tokens": self.completion_tokens,
            "queue_seconds": _round(self.queue_seconds),
            "time_to_first_token": _round(self.time_to_first_token),
            "prompt_tokens_per_second": _round(self.prompt_tokens_per_second, 2),
            "decode_tokens_per_second": _round(self.decode_tokens_per_second, 2),
            "total_seconds": _round(self.total_seconds),
            "finish_reason": self.finish_reason,
            "failed": self.failed,
        }


def _round(value: float | None, digits: int = 4) -> float | None:
    return None if value is None else round(value, digits)


class MetricsRegistry:
    """Thread-safe collection of counters, gauges and recent request history.

    The server is threaded, so every mutation goes through one lock; the work
    under it is trivial next to a forward pass.
    """

    def __init__(self, history: int = 50) -> None:
        self._lock = threading.Lock()
        self._next_id = 0
        self._started_at = time.time()

        self.model_name: str | None = None
        self.model_loaded_at: float | None = None
        self.model_load_seconds: float | None = None

        self._active: dict[int, RequestRecord] = {}
        self._history: deque[RequestRecord] = deque(maxlen=history)

        self.requests_total = 0
        self.requests_failed = 0
        self.prompt_tokens_total = 0
        self.cached_prompt_tokens_total = 0
        self.completion_tokens_total = 0
        self.decode_seconds_total = 0.0

    # -- lifecycle ----------------------------------------------------------

    def note_model_loaded(self, name: str, load_seconds: float | None = None) -> None:
        with self._lock:
            self.model_name = name
            self.model_loaded_at = time.time()
            if load_seconds is not None:
                self.model_load_seconds = load_seconds

    def begin_request(self, model: str) -> RequestRecord:
        with self._lock:
            self._next_id += 1
            record = RequestRecord(
                request_id=self._next_id, model=model, submitted_at=time.perf_counter()
            )
            self._active[record.request_id] = record
            return record

    def note_started(self, record: RequestRecord) -> None:
        with self._lock:
            if record.started_at is None:
                record.started_at = time.perf_counter()

    def note_token(self, record: RequestRecord) -> None:
        with self._lock:
            if record.first_token_at is None:
                record.first_token_at = time.perf_counter()
            record.completion_tokens += 1

    def note_usage(
        self, record: RequestRecord, prompt_tokens: int, cached_tokens: int = 0
    ) -> None:
        with self._lock:
            record.prompt_tokens = prompt_tokens
            record.cached_prompt_tokens = cached_tokens

    def finish_request(
        self, record: RequestRecord, finish_reason: str | None = None, failed: bool = False
    ) -> None:
        with self._lock:
            record.finished_at = time.perf_counter()
            record.finish_reason = finish_reason
            record.failed = failed
            self._active.pop(record.request_id, None)
            self._history.append(record)

            self.requests_total += 1
            if failed:
                self.requests_failed += 1
            self.prompt_tokens_total += record.prompt_tokens
            self.cached_prompt_tokens_total += record.cached_prompt_tokens
            self.completion_tokens_total += record.completion_tokens
            if (seconds := record.decode_seconds) is not None:
                self.decode_seconds_total += seconds

    # -- reads --------------------------------------------------------------

    @property
    def active_requests(self) -> int:
        with self._lock:
            return len(self._active)

    def recent(self, count: int = 10) -> list[RequestRecord]:
        with self._lock:
            return list(self._history)[-count:]

    def last_completed(self) -> RequestRecord | None:
        with self._lock:
            return self._history[-1] if self._history else None

    def live_decode_rate(self) -> float | None:
        """Aggregate decode rate of requests generating right now.

        Without this the reported rate only updates when a request finishes,
        which makes a monitor lag a whole generation behind. Summing across
        in-flight requests gives total throughput, which is what a batching
        server actually delivers.
        """
        now = time.perf_counter()
        with self._lock:
            active = [
                record for record in self._active.values()
                if record.first_token_at is not None and record.completion_tokens > 1
            ]
        if not active:
            return None
        total = 0.0
        for record in active:
            elapsed = now - (record.first_token_at or now)
            if elapsed > 0.05:
                total += (record.completion_tokens - 1) / elapsed
        return total if total > 0 else None

    def rolling_decode_rate(self, window: int = 5) -> float | None:
        """Token-weighted decode rate over the last few requests.

        Weighting by tokens rather than averaging the per-request rates keeps
        one tiny request from dominating the figure.
        """
        with self._lock:
            recent = [
                record for record in list(self._history)[-window:]
                if record.decode_tokens_per_second is not None
            ]
        if not recent:
            return None
        tokens = sum(record.completion_tokens - 1 for record in recent)
        seconds = sum(record.decode_seconds or 0 for record in recent)
        return tokens / seconds if seconds > 0 else None

    def uptime_seconds(self) -> float:
        return time.time() - self._started_at

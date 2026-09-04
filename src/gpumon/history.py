"""Fixed-length series used to draw the sparklines."""

from __future__ import annotations

from collections import deque

_BLOCKS = "▁▂▃▄▅▆▇█"


class Series:
    """A bounded history of one metric."""

    def __init__(self, capacity: int = 240) -> None:
        self._values: deque[float] = deque(maxlen=capacity)

    def push(self, value: float | None) -> None:
        self._values.append(0.0 if value is None else float(value))

    def __len__(self) -> int:
        return len(self._values)

    @property
    def values(self) -> list[float]:
        return list(self._values)

    @property
    def latest(self) -> float | None:
        return self._values[-1] if self._values else None

    @property
    def peak(self) -> float:
        return max(self._values) if self._values else 0.0

    @property
    def mean(self) -> float:
        return sum(self._values) / len(self._values) if self._values else 0.0

    def sparkline(self, width: int, ceiling: float | None = None) -> str:
        """Render the most recent ``width`` samples as block characters.

        ``ceiling`` pins the top of the scale (e.g. 100 for a percentage) so the
        line does not silently rescale itself between frames.
        """
        if width <= 0 or not self._values:
            return ""
        window = list(self._values)[-width:]
        top = ceiling if ceiling is not None else max(window)
        if not top or top <= 0:
            return _BLOCKS[0] * len(window)
        out = []
        for value in window:
            ratio = min(1.0, max(0.0, value / top))
            out.append(_BLOCKS[min(len(_BLOCKS) - 1, int(ratio * (len(_BLOCKS) - 1) + 0.5))])
        return "".join(out)


class History:
    """The set of series the dashboard draws."""

    def __init__(self, capacity: int = 240) -> None:
        self.gpu = Series(capacity)
        self.gpu_power = Series(capacity)
        self.cpu = Series(capacity)
        self.bandwidth = Series(capacity)
        self.gpu_memory = Series(capacity)
        self.system_power = Series(capacity)

    def push(self, snapshot) -> None:
        self.gpu.push(snapshot.gpu.active_pct)
        self.gpu_power.push(snapshot.power.gpu_w)
        self.cpu.push(snapshot.cpu_pct)
        self.bandwidth.push(snapshot.bandwidth.dram_total_gbps)
        self.gpu_memory.push(snapshot.memory.gpu_used)
        self.system_power.push(snapshot.power.system_w)

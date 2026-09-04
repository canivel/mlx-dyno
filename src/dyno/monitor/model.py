"""Data model for a single monitoring sample."""

from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any

GB = 1024 ** 3


@dataclass(frozen=True)
class SystemInfo:
    chip: str
    gpu_cores: int | None
    cpu_cores: int
    performance_cores: int | None
    efficiency_cores: int | None
    total_memory: int
    gpu_memory_budget: int | None
    gpu_frequencies_mhz: tuple[float, ...]
    peak_memory_bandwidth_gbps: float | None
    macos_version: str

    @property
    def gpu_max_mhz(self) -> float | None:
        return max(self.gpu_frequencies_mhz) if self.gpu_frequencies_mhz else None


@dataclass
class GpuSample:
    active_pct: float
    frequency_mhz: float | None
    pstate_residency: dict[str, float]
    allocated_bytes: int | None
    in_use_bytes: int | None
    throttle_events: int
    power_target_pct: float | None


@dataclass
class MemorySample:
    total: int
    used: int
    app: int
    wired: int
    compressed: int
    free: int
    cached: int
    swap_used: int
    swap_total: int
    pressure_pct: float
    gpu_budget: int | None
    gpu_used: int | None

    @property
    def gpu_headroom(self) -> int | None:
        if self.gpu_budget is None or self.gpu_used is None:
            return None
        return max(0, self.gpu_budget - self.gpu_used)

    @property
    def gpu_used_pct(self) -> float | None:
        if not self.gpu_budget or self.gpu_used is None:
            return None
        return 100.0 * self.gpu_used / self.gpu_budget


@dataclass
class PowerSample:
    gpu_w: float | None
    cpu_w: float | None
    dram_w: float | None
    ane_w: float | None
    system_w: float | None
    adapter_max_w: float | None
    on_battery: bool
    battery_pct: int | None

    @property
    def package_w(self) -> float | None:
        parts = [p for p in (self.gpu_w, self.cpu_w, self.dram_w, self.ane_w) if p is not None]
        return sum(parts) if parts else None


@dataclass
class BandwidthSample:
    dram_read_gbps: float | None
    dram_write_gbps: float | None
    gpu_gbps: float | None

    @property
    def dram_total_gbps(self) -> float | None:
        parts = [p for p in (self.dram_read_gbps, self.dram_write_gbps) if p is not None]
        return sum(parts) if parts else None


@dataclass
class ProcessSample:
    pid: int
    name: str
    runtime: str | None
    memory: int
    cpu_pct: float
    uses_gpu: bool
    command: str


@dataclass
class Snapshot:
    timestamp: float
    interval: float
    gpu: GpuSample
    memory: MemorySample
    power: PowerSample
    bandwidth: BandwidthSample
    cpu_pct: float
    processes: list[ProcessSample] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["memory"]["gpu_headroom"] = self.memory.gpu_headroom
        data["memory"]["gpu_used_pct"] = self.memory.gpu_used_pct
        data["power"]["package_w"] = self.power.package_w
        data["bandwidth"]["dram_total_gbps"] = self.bandwidth.dram_total_gbps
        return data

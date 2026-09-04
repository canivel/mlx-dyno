"""Non-interactive output formats: JSON lines, CSV logging, and a one-shot report."""

from __future__ import annotations

import csv
import json
import sys
from typing import TextIO

from .model import GB, Snapshot, SystemInfo

CSV_COLUMNS = (
    "timestamp",
    "interval_s",
    "gpu_busy_pct",
    "gpu_mhz",
    "gpu_w",
    "gpu_throttle_events",
    "cpu_busy_pct",
    "cpu_w",
    "dram_w",
    "ane_w",
    "soc_w",
    "system_w",
    "gpu_memory_bytes",
    "gpu_memory_budget_bytes",
    "gpu_memory_pct",
    "memory_used_bytes",
    "memory_wired_bytes",
    "memory_compressed_bytes",
    "swap_used_bytes",
    "dram_read_gbps",
    "dram_write_gbps",
    "dram_total_gbps",
)


def snapshot_row(snapshot: Snapshot) -> dict[str, object]:
    return {
        "timestamp": round(snapshot.timestamp, 3),
        "interval_s": round(snapshot.interval, 4),
        "gpu_busy_pct": round(snapshot.gpu.active_pct, 2),
        "gpu_mhz": round(snapshot.gpu.frequency_mhz, 1) if snapshot.gpu.frequency_mhz else "",
        "gpu_w": _round(snapshot.power.gpu_w),
        "gpu_throttle_events": snapshot.gpu.throttle_events,
        "cpu_busy_pct": round(snapshot.cpu_pct, 2),
        "cpu_w": _round(snapshot.power.cpu_w),
        "dram_w": _round(snapshot.power.dram_w),
        "ane_w": _round(snapshot.power.ane_w),
        "soc_w": _round(snapshot.power.package_w),
        "system_w": _round(snapshot.power.system_w),
        "gpu_memory_bytes": snapshot.memory.gpu_used or "",
        "gpu_memory_budget_bytes": snapshot.memory.gpu_budget or "",
        "gpu_memory_pct": _round(snapshot.memory.gpu_used_pct, 2),
        "memory_used_bytes": snapshot.memory.used,
        "memory_wired_bytes": snapshot.memory.wired,
        "memory_compressed_bytes": snapshot.memory.compressed,
        "swap_used_bytes": snapshot.memory.swap_used,
        "dram_read_gbps": _round(snapshot.bandwidth.dram_read_gbps),
        "dram_write_gbps": _round(snapshot.bandwidth.dram_write_gbps),
        "dram_total_gbps": _round(snapshot.bandwidth.dram_total_gbps),
    }


def _round(value: float | None, digits: int = 3) -> float | str:
    return "" if value is None else round(value, digits)


class CsvLogger:
    """Appends one row per sample, for benchmarking a model run."""

    def __init__(self, path: str) -> None:
        self._handle = open(path, "w", newline="", encoding="utf-8")
        self._writer = csv.DictWriter(self._handle, fieldnames=CSV_COLUMNS)
        self._writer.writeheader()

    def write(self, snapshot: Snapshot) -> None:
        self._writer.writerow(snapshot_row(snapshot))
        self._handle.flush()

    def close(self) -> None:
        self._handle.close()


def write_json_line(snapshot: Snapshot, stream: TextIO = sys.stdout) -> None:
    stream.write(json.dumps(snapshot.to_dict(), separators=(",", ":")) + "\n")
    stream.flush()


def system_dict(system: SystemInfo) -> dict[str, object]:
    return {
        "chip": system.chip,
        "gpu_cores": system.gpu_cores,
        "cpu_cores": system.cpu_cores,
        "performance_cores": system.performance_cores,
        "efficiency_cores": system.efficiency_cores,
        "total_memory": system.total_memory,
        "gpu_memory_budget": system.gpu_memory_budget,
        "gpu_max_mhz": system.gpu_max_mhz,
        "peak_memory_bandwidth_gbps": system.peak_memory_bandwidth_gbps,
        "macos_version": system.macos_version,
    }


def plain_report(system: SystemInfo, snapshot: Snapshot) -> str:
    """A single human-readable snapshot, for scripts and `--once`."""

    def gb(value: float | None) -> str:
        return "--" if value is None else f"{value / GB:.1f} GB"

    def watts(value: float | None) -> str:
        return "--" if value is None else f"{value:.1f} W"

    memory = snapshot.memory
    lines = [
        f"{system.chip} · {system.gpu_cores or '?'}-core GPU · {gb(system.total_memory)} unified"
        f" · macOS {system.macos_version}",
        "",
        f"GPU busy         {snapshot.gpu.active_pct:.1f}%"
        + (f"  @ {snapshot.gpu.frequency_mhz:.0f} MHz" if snapshot.gpu.frequency_mhz else ""),
        f"GPU power        {watts(snapshot.power.gpu_w)}",
        f"GPU memory       {gb(memory.gpu_used)} of {gb(memory.gpu_budget)}"
        + (f" ({memory.gpu_used_pct:.1f}%)" if memory.gpu_used_pct is not None else "")
        + (f", headroom {gb(memory.gpu_headroom)}" if memory.gpu_headroom is not None else ""),
        f"System memory    {gb(memory.used)} of {gb(memory.total)}"
        f"  (wired {gb(memory.wired)}, compressed {gb(memory.compressed)},"
        f" swap {gb(memory.swap_used)})",
        f"CPU busy         {snapshot.cpu_pct:.1f}%   power {watts(snapshot.power.cpu_w)}",
        f"DRAM power       {watts(snapshot.power.dram_w)}",
        f"SoC power        {watts(snapshot.power.package_w)}",
        f"System power     {watts(snapshot.power.system_w)}"
        + (f" of {snapshot.power.adapter_max_w:.0f} W adapter" if snapshot.power.adapter_max_w else ""),
    ]

    total_bw = snapshot.bandwidth.dram_total_gbps
    if total_bw is not None:
        line = f"Memory bandwidth {total_bw:.0f} GB/s (read {snapshot.bandwidth.dram_read_gbps or 0:.0f}," \
               f" write {snapshot.bandwidth.dram_write_gbps or 0:.0f})"
        if system.peak_memory_bandwidth_gbps:
            line += f" of {system.peak_memory_bandwidth_gbps:.0f} GB/s peak"
        lines.append(line)

    if snapshot.processes:
        lines += ["", "Processes:"]
        for process in snapshot.processes:
            lines.append(
                f"  {process.pid:>7}  {process.name:<26} {process.runtime or '-':<10}"
                f" {process.memory / GB:>6.1f} GB  {process.cpu_pct:>5.0f}%"
                f"  {'GPU' if process.uses_gpu else '   '}"
            )

    if snapshot.warnings:
        lines += ["", "Warnings:"]
        lines += [f"  ! {message}" for message in snapshot.warnings]

    return "\n".join(lines)

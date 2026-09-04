"""Composes the individual collectors into a single Snapshot per interval."""

from __future__ import annotations

import re
import time
from typing import Iterable

from . import sources
from .cf import metal_device_info
from .ioreport import FORMAT_STATE, Channel, IOReportError, Subscription
from .model import (
    BandwidthSample,
    GB,
    GpuSample,
    MemorySample,
    PowerSample,
    ProcessSample,
    Snapshot,
    SystemInfo,
)

_GPU_STATS_SUBGROUPS = (
    ("GPU Stats", "GPU Performance States"),
    ("GPU Stats", "GPU Throttler Counters"),
    ("GPU Stats", "PPM Target as % of Max GPU Power"),
)
# The memory-controller bandwidth histograms live under a per-die power
# management group. PMP0 is the usual name; the alternates are tried only if it
# yields nothing, so the common case pays for one lookup.
_BANDWIDTH_GROUP = ("PMP0", "DCS BW")
_BANDWIDTH_FALLBACKS = (("PMP", "DCS BW"), ("PMP1", "DCS BW"))

_BUCKET_LABEL = re.compile(r"([0-9.]+)\s*(GB|MB|KB)/s")
_UNIT_TO_GB = {"GB": 1.0, "MB": 1 / 1024, "KB": 1 / 1024 ** 2}
_PERCENT_LABEL = re.compile(r"([0-9.]+)\s*%")

# Channels actually read out of each group. Everything else in the subscribed
# subgroups is skipped before its state array is decoded.
_ENERGY_CHANNELS = frozenset({"GPU Energy", "GPU", "CPU Energy", "DRAM", "ANE"})
_BANDWIDTH_CHANNELS = frozenset({"AMCC RD", "AMCC WR"})

# Scanning the process table costs far more than every other collector
# combined, and process memory does not move on a 100 ms timescale.
_PROCESS_REFRESH_SECONDS = 2.0

# Above this share of the Metal working-set budget, further allocations start
# competing with the rest of the system.
_GPU_MEMORY_WARN_PCT = 90.0
_COMPRESSOR_WARN = 8 * GB


def _is_gpu_residency(channel: Channel) -> bool:
    if channel.format != FORMAT_STATE or channel.group != "GPU Stats":
        return False
    names = {name for name, _ in channel.states}
    return "OFF" in names and "P1" in names


def _histogram_mean(states: Iterable[tuple[str, int]]) -> tuple[float, bool] | None:
    """Mean of a bandwidth histogram whose state names are bucket upper edges.

    Returns (GB/s, clipped) where ``clipped`` marks residency in the top bucket,
    meaning the real value may be higher than reported.
    """
    edges: list[tuple[float, int]] = []
    for label, residency in states:
        match = _BUCKET_LABEL.search(label)
        if not match:
            return None
        edges.append((float(match.group(1)) * _UNIT_TO_GB[match.group(2)], residency))
    total = sum(residency for _, residency in edges)
    if total <= 0 or len(edges) < 2:
        return None
    width = edges[1][0] - edges[0][0]
    mean = sum((edge - width / 2) * residency for edge, residency in edges) / total
    return mean, edges[-1][1] > 0


def _state_percent_mean(states: Iterable[tuple[str, int]]) -> float | None:
    values: list[tuple[float, int]] = []
    for label, residency in states:
        match = _PERCENT_LABEL.search(label)
        if not match:
            return None
        values.append((float(match.group(1)), residency))
    total = sum(residency for _, residency in values)
    if total <= 0:
        return None
    return sum(value * residency for value, residency in values) / total


class Sampler:
    """Holds the IOReport subscription and turns each interval into a Snapshot."""

    def __init__(self, *, peak_bandwidth: float | None = None, process_limit: int = 8,
                 process_min_memory: int = GB) -> None:
        self.process_limit = process_limit
        self.process_min_memory = process_min_memory
        self._cpu_load = sources.CpuLoad()
        self._previous_swapouts: int | None = None
        self._processes: list[ProcessSample] = []
        self._processes_at = 0.0

        accelerator = sources.accelerator_properties()
        metal = metal_device_info()
        chip = (
            metal.get("name")
            or accelerator.get("model")
            or sources.sysctl_str("machdep.cpu.brand_string")
            or "Apple Silicon"
        )
        gpu_cores = accelerator.get("cores")
        total_memory = sources.sysctl_int("hw.memsize") or 0

        self.system = SystemInfo(
            chip=chip,
            gpu_cores=gpu_cores if isinstance(gpu_cores, int) else None,
            cpu_cores=sources.sysctl_int("hw.ncpu") or 0,
            performance_cores=sources.sysctl_int("hw.perflevel0.logicalcpu"),
            efficiency_cores=sources.sysctl_int("hw.perflevel1.logicalcpu"),
            total_memory=total_memory,
            gpu_memory_budget=metal.get("recommended_max_working_set"),
            gpu_frequencies_mhz=sources.gpu_frequency_table(),
            peak_memory_bandwidth_gbps=peak_bandwidth
            or sources.peak_bandwidth_gbps(chip, gpu_cores if isinstance(gpu_cores, int) else None),
            macos_version=sources.macos_version(),
        )

        self._subscription = self._subscribe((_BANDWIDTH_GROUP,))
        if not self._subscription.has_subgroup("DCS BW"):
            # Some SoCs name the power-management group differently; pay for the
            # extra lookups only on those.
            self._subscription.close()
            self._subscription = self._subscribe(
                (_BANDWIDTH_GROUP,) + _BANDWIDTH_FALLBACKS
            )

    def _subscribe(self, bandwidth_groups: tuple[tuple[str, str | None], ...]) -> Subscription:
        groups = list(_GPU_STATS_SUBGROUPS) + [("Energy Model", None)] + list(bandwidth_groups)
        try:
            return Subscription(groups)
        except IOReportError:
            # Fall back to the whole GPU Stats group on SoCs that name their
            # performance-state subgroup differently.
            return Subscription([("GPU Stats", None), ("Energy Model", None)])



    def close(self) -> None:
        self._subscription.close()

    @staticmethod
    def _keep_channel(group: str, subgroup: str | None, name: str) -> bool:
        if group == "Energy Model":
            return name in _ENERGY_CHANNELS
        if subgroup == "DCS BW":
            return name in _BANDWIDTH_CHANNELS
        if group == "GPU Stats":
            if subgroup == "GPU Throttler Counters":
                return name == "Throttle Counter Total"
            return True
        return False

    def _process_samples(self) -> list[ProcessSample]:
        now = time.monotonic()
        if self._processes and now - self._processes_at < _PROCESS_REFRESH_SECONDS:
            return self._processes
        gpu_pids = sources.gpu_client_pids()
        self._processes = [
            ProcessSample(**row)
            for row in sources.process_table(
                gpu_pids, self.process_min_memory, self.process_limit
            )
        ]
        self._processes_at = now
        return self._processes

    def sample(self) -> Snapshot:
        channels, interval = self._subscription.sample(self._keep_channel)
        interval = max(interval, 1e-6)

        gpu_active = 0.0
        gpu_mhz: float | None = None
        residency: dict[str, float] = {}
        throttle_events = 0
        power_target: float | None = None
        gpu_w = cpu_w = dram_w = ane_w = None
        read_gbps = write_gbps = None
        bandwidth_clipped = False

        for channel in channels:
            if _is_gpu_residency(channel):
                gpu_active, gpu_mhz, residency = self._decode_residency(channel)
            elif channel.group == "GPU Stats" and channel.name == "Throttle Counter Total":
                throttle_events = channel.value or 0
            elif channel.group == "GPU Stats" and channel.format == FORMAT_STATE and (
                channel.subgroup or ""
            ).startswith("PPM Target"):
                power_target = _state_percent_mean(channel.states)
            elif channel.group == "Energy Model":
                joules = channel.energy_joules()
                if joules is None:
                    continue
                watts = joules / interval
                if channel.name == "GPU Energy":
                    gpu_w = watts
                elif channel.name == "GPU" and gpu_w is None:
                    gpu_w = watts
                elif channel.name == "CPU Energy":
                    cpu_w = watts
                elif channel.name == "DRAM":
                    dram_w = watts
                elif channel.name == "ANE":
                    ane_w = watts
            elif channel.subgroup == "DCS BW" and channel.name in ("AMCC RD", "AMCC WR"):
                result = _histogram_mean(channel.states)
                if result is None:
                    continue
                mean, clipped = result
                bandwidth_clipped = bandwidth_clipped or clipped
                if channel.name == "AMCC RD":
                    read_gbps = mean
                else:
                    write_gbps = mean

        accelerator = sources.accelerator_properties()
        stats = accelerator.get("stats") or {}
        gpu_allocated = stats.get("Alloc system memory")
        gpu_in_use = stats.get("In use system memory")

        vm = sources.vm_statistics()
        swap_used, swap_total = sources.swap_usage()
        total_memory = self.system.total_memory
        wired = vm.get("wired", 0)
        compressed = vm.get("compressed", 0)
        app = vm.get("app", 0)
        used = app + wired + compressed
        pressure = 100.0 * (wired + compressed) / total_memory if total_memory else 0.0

        memory = MemorySample(
            total=total_memory,
            used=used,
            app=app,
            wired=wired,
            compressed=compressed,
            free=vm.get("free", 0),
            cached=vm.get("external", 0),
            swap_used=swap_used,
            swap_total=swap_total,
            pressure_pct=pressure,
            gpu_budget=self.system.gpu_memory_budget,
            gpu_used=gpu_in_use if isinstance(gpu_in_use, int) else None,
        )

        source = sources.power_source()
        power = PowerSample(
            gpu_w=gpu_w,
            cpu_w=cpu_w,
            dram_w=dram_w,
            ane_w=ane_w,
            system_w=source["system_w"],
            adapter_max_w=source["adapter_max_w"],
            on_battery=source["on_battery"],
            battery_pct=source["battery_pct"],
        )

        processes = self._process_samples()

        snapshot = Snapshot(
            timestamp=time.time(),
            interval=interval,
            gpu=GpuSample(
                active_pct=gpu_active,
                frequency_mhz=gpu_mhz,
                pstate_residency=residency,
                allocated_bytes=gpu_allocated if isinstance(gpu_allocated, int) else None,
                in_use_bytes=gpu_in_use if isinstance(gpu_in_use, int) else None,
                throttle_events=throttle_events,
                power_target_pct=power_target,
            ),
            memory=memory,
            power=power,
            bandwidth=BandwidthSample(
                dram_read_gbps=read_gbps, dram_write_gbps=write_gbps, gpu_gbps=None
            ),
            cpu_pct=self._cpu_load.sample(),
            processes=processes,
        )
        snapshot.warnings = self._warnings(snapshot, vm)
        if bandwidth_clipped:
            snapshot.warnings.append(
                "Memory bandwidth is saturating the controller's top histogram "
                "bucket - the real figure may be higher than shown"
            )
        return snapshot

    def _decode_residency(self, channel: Channel) -> tuple[float, float | None, dict[str, float]]:
        """GPU busy percentage and average clock, from time spent per P-state."""
        total = sum(value for _, value in channel.states)
        if total <= 0:
            return 0.0, None, {}
        residency = {name: 100.0 * value / total for name, value in channel.states}
        idle = residency.get("OFF", 0.0)
        active = max(0.0, 100.0 - idle)

        frequencies = self.system.gpu_frequencies_mhz
        mhz: float | None = None
        if frequencies:
            weighted = 0.0
            active_share = 0.0
            for index, (name, value) in enumerate(channel.states):
                if name == "OFF" or index >= len(frequencies):
                    continue
                share = value / total
                weighted += frequencies[index] * share
                active_share += share
            # Report the clock the GPU runs at while busy, not averaged with idle.
            mhz = weighted / active_share if active_share > 0 else None
        return active, mhz, residency

    def _warnings(self, snapshot: Snapshot, vm: dict[str, int]) -> list[str]:
        warnings: list[str] = []
        memory = snapshot.memory

        used_pct = memory.gpu_used_pct
        if used_pct is not None and used_pct >= _GPU_MEMORY_WARN_PCT:
            warnings.append(
                "GPU memory at %.0f%% of the Metal working-set budget - "
                "further allocations may spill to CPU memory" % used_pct
            )

        swapouts = vm.get("swapouts", 0)
        if self._previous_swapouts is not None and swapouts > self._previous_swapouts:
            warnings.append(
                "Actively swapping (%s written since last sample) - "
                "token throughput will drop sharply"
                % _format_bytes((swapouts - self._previous_swapouts) * sources.PAGE_SIZE)
            )
        self._previous_swapouts = swapouts

        if memory.compressed >= _COMPRESSOR_WARN:
            warnings.append(
                "Memory compressor holding %s - the model no longer fits comfortably"
                % _format_bytes(memory.compressed)
            )

        if snapshot.gpu.throttle_events > 0:
            warnings.append(
                "GPU throttled %d time(s) this interval" % snapshot.gpu.throttle_events
            )

        power = snapshot.power
        if (
            power.system_w is not None
            and power.adapter_max_w
            and power.system_w > power.adapter_max_w
        ):
            warnings.append(
                "Drawing %.0f W from a %.0f W adapter - the battery is making up the difference"
                % (power.system_w, power.adapter_max_w)
            )
        elif power.on_battery:
            warnings.append("On battery - the GPU may be held below its plugged-in clocks")

        return warnings


def _format_bytes(value: float) -> str:
    for unit, scale in (("TB", 1024 ** 4), ("GB", GB), ("MB", 1024 ** 2), ("KB", 1024)):
        if abs(value) >= scale:
            return "%.1f %s" % (value / scale, unit)
    return "%d B" % value

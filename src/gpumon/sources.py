"""Collectors for every metric gpumon reports.

Each function here talks to exactly one system interface and returns plain
Python values, so the sampler can compose them without caring how the number
was obtained.
"""

from __future__ import annotations

import ctypes
import os
import re
import struct
import subprocess
from ctypes import byref, c_char_p, c_size_t, c_uint32, c_void_p
from typing import Any

from . import cf

libc = ctypes.CDLL(None)

# --- sysctl -----------------------------------------------------------------

libc.sysctlbyname.restype = ctypes.c_int
libc.sysctlbyname.argtypes = [c_char_p, c_void_p, ctypes.POINTER(c_size_t), c_void_p, c_size_t]


def sysctl_raw(name: str) -> bytes | None:
    size = c_size_t(0)
    if libc.sysctlbyname(name.encode(), None, byref(size), None, 0) != 0:
        return None
    buf = ctypes.create_string_buffer(size.value)
    if libc.sysctlbyname(name.encode(), buf, byref(size), None, 0) != 0:
        return None
    return buf.raw[: size.value]


def sysctl_int(name: str) -> int | None:
    raw = sysctl_raw(name)
    if raw is None:
        return None
    if len(raw) >= 8:
        return struct.unpack("<q", raw[:8])[0]
    if len(raw) >= 4:
        return struct.unpack("<i", raw[:4])[0]
    return None


def sysctl_str(name: str) -> str | None:
    raw = sysctl_raw(name)
    if raw is None:
        return None
    return raw.split(b"\x00", 1)[0].decode("utf-8", "replace")


# --- mach virtual memory statistics ----------------------------------------

_HOST_VM_INFO64 = 4
_HOST_CPU_LOAD_INFO = 3


class _VMStatistics64(ctypes.Structure):
    _fields_ = [
        ("free_count", ctypes.c_uint32),
        ("active_count", ctypes.c_uint32),
        ("inactive_count", ctypes.c_uint32),
        ("wire_count", ctypes.c_uint32),
        ("zero_fill_count", ctypes.c_uint64),
        ("reactivations", ctypes.c_uint64),
        ("pageins", ctypes.c_uint64),
        ("pageouts", ctypes.c_uint64),
        ("faults", ctypes.c_uint64),
        ("cow_faults", ctypes.c_uint64),
        ("lookups", ctypes.c_uint64),
        ("hits", ctypes.c_uint64),
        ("purges", ctypes.c_uint64),
        ("purgeable_count", ctypes.c_uint32),
        ("speculative_count", ctypes.c_uint32),
        ("decompressions", ctypes.c_uint64),
        ("compressions", ctypes.c_uint64),
        ("swapins", ctypes.c_uint64),
        ("swapouts", ctypes.c_uint64),
        ("compressor_page_count", ctypes.c_uint32),
        ("throttled_count", ctypes.c_uint32),
        ("external_page_count", ctypes.c_uint32),
        ("internal_page_count", ctypes.c_uint32),
        ("total_uncompressed_pages_in_compressor", ctypes.c_uint64),
    ]


libc.mach_host_self.restype = c_uint32
libc.host_statistics64.restype = ctypes.c_int
libc.host_statistics64.argtypes = [c_uint32, ctypes.c_int, c_void_p, ctypes.POINTER(c_uint32)]
libc.host_statistics.restype = ctypes.c_int
libc.host_statistics.argtypes = [c_uint32, ctypes.c_int, c_void_p, ctypes.POINTER(c_uint32)]

PAGE_SIZE = sysctl_int("hw.pagesize") or 16384
_mach_host = libc.mach_host_self()


def vm_statistics() -> dict[str, int]:
    """Page counts from the kernel, already multiplied out to bytes."""
    stats = _VMStatistics64()
    count = c_uint32(ctypes.sizeof(_VMStatistics64) // 4)
    if libc.host_statistics64(_mach_host, _HOST_VM_INFO64, byref(stats), byref(count)) != 0:
        return {}
    internal = stats.internal_page_count
    purgeable = stats.purgeable_count
    return {
        "free": (stats.free_count - stats.speculative_count) * PAGE_SIZE,
        "active": stats.active_count * PAGE_SIZE,
        "inactive": stats.inactive_count * PAGE_SIZE,
        "wired": stats.wire_count * PAGE_SIZE,
        "compressed": stats.compressor_page_count * PAGE_SIZE,
        "speculative": stats.speculative_count * PAGE_SIZE,
        "purgeable": purgeable * PAGE_SIZE,
        "app": max(0, internal - purgeable) * PAGE_SIZE,
        "external": stats.external_page_count * PAGE_SIZE,
        "swapins": stats.swapins,
        "swapouts": stats.swapouts,
    }


class CpuLoad:
    """Whole-machine CPU utilisation, derived from tick deltas."""

    def __init__(self) -> None:
        self._previous = self._ticks()

    @staticmethod
    def _ticks() -> tuple[int, int, int, int] | None:
        buf = (c_uint32 * 4)()
        count = c_uint32(4)
        if libc.host_statistics(_mach_host, _HOST_CPU_LOAD_INFO, byref(buf), byref(count)) != 0:
            return None
        return tuple(buf)  # user, system, idle, nice

    def sample(self) -> float:
        current = self._ticks()
        if current is None or self._previous is None:
            self._previous = current
            return 0.0
        busy = sum(current[i] - self._previous[i] for i in (0, 1, 3))
        total = busy + (current[2] - self._previous[2])
        self._previous = current
        if total <= 0:
            return 0.0
        return 100.0 * busy / total


def swap_usage() -> tuple[int, int]:
    """(used, total) swap bytes."""
    raw = sysctl_raw("vm.swapusage")
    if raw and len(raw) >= 24:
        total, avail, used = struct.unpack("<qqq", raw[:24])
        return used, total
    return 0, 0


# --- GPU --------------------------------------------------------------------

_ACCELERATOR_CLASSES = ("AGXAccelerator", "IOAccelerator")


def accelerator_properties() -> dict[str, Any]:
    """PerformanceStatistics plus identity keys from the Apple GPU driver."""
    for class_name in _ACCELERATOR_CLASSES:
        for entry in cf.matching_services(class_name):
            stats = cf.entry_property(entry, "PerformanceStatistics")
            if not isinstance(stats, dict):
                continue
            return {
                "stats": stats,
                "cores": cf.entry_property(entry, "gpu-core-count"),
                "model": cf.entry_property(entry, "model"),
            }
    return {}


def gpu_frequency_table() -> tuple[float, ...]:
    """GPU DVFS frequencies in MHz, index-aligned with the GPUPH P-states.

    The kernel publishes the table as (frequency Hz, voltage mV) pairs under the
    power manager node. Index 0 is the idle/off state.
    """
    for entry in cf.matching_services("AppleARMIODevice"):
        raw = cf.entry_property(entry, "voltage-states9")
        if not isinstance(raw, (bytes, bytearray)) or len(raw) < 8:
            continue
        words = struct.unpack("<%dI" % (len(raw) // 4), bytes(raw[: (len(raw) // 4) * 4]))
        return tuple(words[i] / 1e6 for i in range(0, len(words) - 1, 2))
    return ()


def gpu_client_pids() -> set[int]:
    """PIDs holding an open GPU user client, i.e. processes actually able to
    submit Metal work right now."""
    pids: set[int] = set()
    pattern = re.compile(r"pid (\d+)")

    def walk(entry: int, depth: int) -> None:
        if depth > 4:
            return
        creator = cf.entry_property(entry, "IOUserClientCreator")
        if isinstance(creator, str):
            match = pattern.search(creator)
            if match:
                pids.add(int(match.group(1)))
        for child in cf.child_entries(entry):
            walk(child, depth + 1)

    for class_name in _ACCELERATOR_CLASSES:
        found = False
        for entry in cf.matching_services(class_name):
            found = True
            walk(entry, 0)
        if found:
            break
    return pids


# --- power source -----------------------------------------------------------


def power_source() -> dict[str, Any]:
    """Whole-system power draw and battery state.

    ``SystemPowerIn`` in the SMC power telemetry block is the wall/battery draw
    for the entire machine in milliwatts -- the number that tells a laptop user
    whether a run is outrunning the charger.
    """
    for entry in cf.matching_services("IOPMPowerSource"):
        props = cf.entry_properties(entry)
        telemetry = props.get("PowerTelemetryData") or {}
        adapter = props.get("AdapterDetails") or {}
        system_mw = telemetry.get("SystemPowerIn")
        return {
            "system_w": (system_mw / 1000.0) if isinstance(system_mw, int) and system_mw else None,
            "adapter_max_w": adapter.get("Watts"),
            "on_battery": not bool(props.get("ExternalConnected")),
            "battery_pct": props.get("CurrentCapacity"),
        }
    return {"system_w": None, "adapter_max_w": None, "on_battery": False, "battery_pct": None}


# --- processes --------------------------------------------------------------

# Ordered most specific first; the first rule whose pattern matches the command
# line decides the label.
_RUNTIME_RULES: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("ollama", re.compile(r"\bollama\b", re.I)),
    ("llama.cpp", re.compile(r"\b(llama-server|llama-cli|llama-bench|llama-run|llama-quantize)\b", re.I)),
    ("LM Studio", re.compile(r"LM Studio|lmstudio|\blms\b", re.I)),
    ("MLX", re.compile(r"\bmlx[_.-]?(lm|vlm|whisper|server)?\b", re.I)),
    ("vLLM", re.compile(r"\bvllm\b", re.I)),
    ("llama.cpp", re.compile(r"llama\.cpp|llamacpp", re.I)),
    ("koboldcpp", re.compile(r"koboldcpp", re.I)),
    ("text-gen", re.compile(r"text-generation-(server|webui)|\btgi\b", re.I)),
    ("whisper.cpp", re.compile(r"whisper-(cli|server)|whisper\.cpp", re.I)),
    ("ComfyUI", re.compile(r"comfyui|ComfyUI", re.I)),
    ("PyTorch", re.compile(r"\btorchrun\b|torch\.distributed", re.I)),
    ("Diffusers", re.compile(r"diffusers|stable[-_]diffusion", re.I)),
)

# Shells and helpers whose command line often merely mentions a runtime name.
_NOT_A_RUNTIME = frozenset(
    {"zsh", "bash", "sh", "fish", "tmux", "screen", "grep", "ps", "tail", "less",
     "vim", "nvim", "code", "man", "watch", "sudo", "env", "xargs", "gpumon"}
)

# A matched runtime is worth showing even when idle, but not when it is a few
# megabytes of launcher.
_RUNTIME_MIN_MEMORY = 64 * 1024 ** 2


def _display_name(command: str) -> str:
    """Best-effort executable name from a command line.

    Handles both ``/Applications/Foo.app/Contents/MacOS/Foo Bar --flag`` (path
    with spaces) and ``ollama runner --model ...`` (bare name plus subcommand).
    """
    head = command.split(" -", 1)[0].strip()
    if head.startswith("/"):
        return os.path.basename(head) or head
    return head.split()[0] if head.split() else command[:24]


def process_table(
    gpu_pids: set[int], min_memory: int, limit: int
) -> list[dict[str, Any]]:
    """Processes that look like an LLM runtime, or that hold a GPU client and a
    meaningful amount of memory."""
    try:
        output = subprocess.run(
            ["ps", "-Ao", "pid=,rss=,pcpu=,args="],
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []

    rows: list[dict[str, Any]] = []
    self_pid = os.getpid()
    for line in output.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid = int(parts[0])
            memory = int(parts[1]) * 1024
            cpu_pct = float(parts[2])
        except ValueError:
            continue
        if pid == self_pid:
            continue

        command = parts[3]
        name = _display_name(command)
        uses_gpu = pid in gpu_pids

        runtime = None
        if name not in _NOT_A_RUNTIME:
            for label, pattern in _RUNTIME_RULES:
                if pattern.search(command):
                    runtime = label
                    break

        known_runtime = runtime is not None and memory >= _RUNTIME_MIN_MEMORY
        if not known_runtime and not (uses_gpu and memory >= min_memory):
            continue

        rows.append(
            {
                "pid": pid,
                "name": name[:26],
                "runtime": runtime,
                "memory": memory,
                "cpu_pct": cpu_pct,
                "uses_gpu": uses_gpu,
                "command": command,
            }
        )

    rows.sort(key=lambda row: (row["runtime"] is None, -row["memory"]))
    return rows[:limit]


# --- machine identity -------------------------------------------------------

# Nominal peak unified-memory bandwidth, GB/s. Only chips with a well
# established figure are listed; anything else reports absolute GB/s with no
# percentage, and can be pinned with --peak-bandwidth.
_PEAK_BANDWIDTH: tuple[tuple[str, float], ...] = (
    ("M1 Ultra", 800.0),
    ("M1 Max", 400.0),
    ("M1 Pro", 200.0),
    ("M1", 68.25),
    ("M2 Ultra", 800.0),
    ("M2 Max", 400.0),
    ("M2 Pro", 200.0),
    ("M2", 100.0),
    ("M3 Ultra", 800.0),
    ("M3 Max", 400.0),
    ("M3 Pro", 150.0),
    ("M3", 100.0),
    ("M4 Max", 546.0),
    ("M4 Pro", 273.0),
    ("M4", 120.0),
)


def peak_bandwidth_gbps(chip: str, gpu_cores: int | None) -> float | None:
    for name, value in _PEAK_BANDWIDTH:
        if name in chip:
            # The binned M3 Max ships a narrower memory bus than the full part.
            if name == "M3 Max" and gpu_cores is not None and gpu_cores <= 30:
                return 300.0
            return value
    return None


def macos_version() -> str:
    try:
        return subprocess.run(
            ["sw_vers", "-productVersion"], capture_output=True, text=True, timeout=5
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""

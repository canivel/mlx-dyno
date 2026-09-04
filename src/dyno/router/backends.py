"""Discovering the model servers the router can send work to, and ranking them.

Ranking is deliberately explainable: capability comes from the parameter count
and quantisation in the model's name, both of which a person can read off the
row and check. A learned scorer would be harder to argue with when the router
makes a choice you disagree with.
"""

from __future__ import annotations

import json
import re
import socket
import subprocess
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any

# Ports commonly used by local model servers, probed when none are configured.
# The 897x block is where `dyno serve` puts them; the rest are other runtimes'
# defaults.
DEFAULT_PORTS = tuple(range(8970, 8980)) + (1234, 8080, 8000, 11434, 5000, 1337)

_PARAM_PATTERN = re.compile(r"(\d+(?:\.\d+)?)\s*([bm])\b", re.I)
_BITS_PATTERN = re.compile(r"(\d+)\s*bit", re.I)
_MOE_PATTERN = re.compile(r"a(\d+(?:\.\d+)?)b", re.I)


@dataclass
class Backend:
    """One model server the router can use."""

    url: str
    model_id: str
    name: str
    port: int
    healthy: bool = True
    # Reported by dyno serve; absent for a plain mlx_lm.server.
    has_stats: bool = False
    measured_tokens_per_second: float | None = None
    active_requests: int = 0
    memory_bytes: int | None = None
    last_seen: float = field(default_factory=time.time)

    @property
    def parameters(self) -> float | None:
        """Parameter count parsed from the name, in billions.

        For mixture-of-experts names like `30B-A3B`, the active parameter count
        is what governs speed, so it wins when present.
        """
        active = _MOE_PATTERN.search(self.name)
        if active:
            return float(active.group(1))
        match = _PARAM_PATTERN.search(self.name)
        if not match:
            return None
        value = float(match.group(1))
        return value / 1000 if match.group(2).lower() == "m" else value

    @property
    def bits(self) -> int | None:
        match = _BITS_PATTERN.search(self.name)
        if match:
            return int(match.group(1))
        lowered = self.name.lower()
        if "bf16" in lowered or "fp16" in lowered:
            return 16
        if "fp8" in lowered or "mxfp8" in lowered:
            return 8
        if "mxfp4" in lowered:
            return 4
        return None

    @property
    def capability(self) -> float:
        """A rough, readable ordering of how strong a model is.

        Parameters dominate; precision breaks ties, because an 8-bit build of a
        model answers better than a 4-bit build of the same one.
        """
        params = self.parameters or 1.0
        bits = self.bits or 8
        # Diminishing returns on size, and a modest bonus for precision.
        return round((params ** 0.7) * (1 + (bits - 4) * 0.03), 3)

    def describe(self) -> dict[str, Any]:
        return {
            "url": self.url,
            "model_id": self.model_id,
            "name": self.name,
            "port": self.port,
            "parameters_b": self.parameters,
            "bits": self.bits,
            "capability": self.capability,
            "tokens_per_second": self.measured_tokens_per_second,
            "active_requests": self.active_requests,
            "resident": True,
            "has_stats": self.has_stats,
        }


def _get(url: str, timeout: float = 1.5) -> Any | None:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            if response.status != 200:
                return None
            return json.loads(response.read().decode())
    except (urllib.error.URLError, OSError, ValueError, TimeoutError):
        return None


_MODEL_FLAG = re.compile(r"--model[= ]+(\S+)")

# Identification is cached per (port, pid): it cannot change while the process
# lives, and an lsof that times out under load must not be allowed to silently
# downgrade a 27B to whatever /v1/models happens to list first.
_IDENTITY_CACHE: dict[tuple[int, str], str] = {}


def _listening_pid(port: int) -> str | None:
    try:
        listing = subprocess.run(
            ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-Fp"],
            capture_output=True, text=True, timeout=6,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in listing.splitlines():
        if line.startswith("p"):
            return line[1:]
    return None


def _model_from_process(port: int) -> str | None:
    """What the server on this port was actually launched with.

    A plain `mlx_lm.server` lists every model in the cache from `/v1/models`,
    not the one it loaded, so trusting that endpoint can have the router
    believe a 27B is a 0.5B. The command line is the truth.
    """
    pid = _listening_pid(port)
    if not pid:
        return None
    if cached := _IDENTITY_CACHE.get((port, pid)):
        return cached
    try:
        args = subprocess.run(
            ["ps", "-p", pid, "-o", "args="],
            capture_output=True, text=True, timeout=6,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    match = _MODEL_FLAG.search(args)
    if not match:
        return None
    _IDENTITY_CACHE[(port, pid)] = match.group(1)
    return match.group(1)


def _port_open(port: int, host: str = "127.0.0.1") -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.12)
        return sock.connect_ex((host, port)) == 0


def probe(port: int, host: str = "127.0.0.1") -> Backend | None:
    """Identify the server on a port, if there is one that can generate."""
    if not _port_open(port, host):
        return None
    base = f"http://{host}:{port}"

    stats = _get(f"{base}/stats")
    # The command line first: it says what the server was told to load, and is
    # right before the model is lazily loaded, when /stats still reports a
    # placeholder and /v1/models lists the whole cache.
    model_id: str | None = _model_from_process(port)
    measured: float | None = None
    active = 0
    memory: int | None = None

    if isinstance(stats, dict) and "live" in stats:
        # dyno serve also reports live throughput, which nothing else does.
        reported = (stats.get("model") or {}).get("name")
        if not model_id and reported and reported != "default_model":
            model_id = reported
        live = stats.get("live") or {}
        measured = live.get("decode_tokens_per_second")
        active = live.get("requests_active") or 0
        memory = (stats.get("memory") or {}).get("active_bytes")

    if not model_id:
        models = _get(f"{base}/v1/models")
        if not isinstance(models, dict):
            return None
        entries = models.get("data") or []
        if not entries:
            return None
        # A plain mlx_lm.server lists everything it *could* serve, so the first
        # entry is a guess. It is still better than not routing to it at all.
        model_id = entries[0].get("id")

    if not model_id:
        return None

    return Backend(
        url=base,
        model_id=model_id,
        name=model_id.split("/")[-1],
        port=port,
        has_stats=bool(stats),
        measured_tokens_per_second=measured,
        active_requests=active,
        memory_bytes=memory,
    )


def discover(
    ports: tuple[int, ...] = DEFAULT_PORTS,
    extra: list[str] | None = None,
    scan: bool = True,
) -> list[Backend]:
    """Every reachable model server, strongest first.

    When explicit backends are given, scanning is off by default: naming them
    should mean "these", not "these as well as whatever else is listening".
    """
    found: dict[str, Backend] = {}

    for port in (ports if scan else ()):
        backend = probe(port)
        if backend:
            found[backend.url] = backend

    for entry in extra or []:
        # Accept "8975" or "127.0.0.1:8975" or a full URL.
        host, _, port_text = entry.rpartition(":")
        host = host.replace("http://", "").replace("https://", "") or "127.0.0.1"
        if not port_text.isdigit():
            continue
        backend = probe(int(port_text), host=host)
        if backend:
            found[backend.url] = backend

    return sorted(found.values(), key=lambda item: item.capability, reverse=True)

"""Terminal dashboard.

Rendering is a pure function of (SystemInfo, History, Snapshot), which keeps the
layout logic testable and lets the export formats reuse the same numbers.
"""

from __future__ import annotations

import time
from datetime import datetime

from rich.console import Group, RenderableType
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

from .history import History
from .model import GB, Snapshot, SystemInfo

FULL = "█"
EMPTY = "░"

# Thresholds shared by every gauge, so a colour means the same thing everywhere.
_WARN_PCT = 70.0
_CRITICAL_PCT = 90.0


def _level_colour(pct: float) -> str:
    if pct >= _CRITICAL_PCT:
        return "bright_red"
    if pct >= _WARN_PCT:
        return "yellow"
    return "green"


def bar(fraction: float, width: int, colour: str | None = None) -> Text:
    fraction = min(1.0, max(0.0, fraction))
    filled = int(round(fraction * width))
    colour = colour or _level_colour(fraction * 100)
    text = Text()
    text.append(FULL * filled, style=colour)
    text.append(EMPTY * (width - filled), style="grey35")
    return text


def fmt_bytes(value: float | None, precision: int = 1) -> str:
    if value is None:
        return "--"
    for unit, scale in (("TB", 1024 ** 4), ("GB", GB), ("MB", 1024 ** 2), ("KB", 1024)):
        if abs(value) >= scale:
            return f"{value / scale:.{precision}f} {unit}"
    return f"{int(value)} B"


def fmt_watts(value: float | None) -> str:
    return "--" if value is None else f"{value:5.1f} W"


class Dashboard:
    def __init__(self, system: SystemInfo, history: History, *, interval: float = 1.0):
        self.system = system
        self.history = history
        self.interval = interval
        self.paused = False
        self.started = time.monotonic()

    # -- header / footer ----------------------------------------------------

    def header(self, snapshot: Snapshot, width: int) -> RenderableType:
        system = self.system
        left = Text()
        left.append("dyno ", style="bold cyan")
        left.append(system.chip, style="bold white")
        details = [f"{system.gpu_cores}-core GPU"] if system.gpu_cores else []
        details.append(f"{fmt_bytes(system.total_memory, 0)} unified")
        if system.cpu_cores and width >= 96:
            details.append(f"{system.cpu_cores}-core CPU")
        left.append("  ·  " + "  ·  ".join(details), style="grey62")

        right = Text()
        if self.paused:
            right.append("PAUSED  ", style="bold yellow")
        right.append(datetime.fromtimestamp(snapshot.timestamp).strftime("%H:%M:%S"), style="white")
        right.append(f"  {self.interval:g}s", style="grey62")

        grid = Table.grid(expand=True)
        grid.add_column(justify="left")
        grid.add_column(justify="right")
        grid.add_row(left, right)
        return grid

    def footer(self) -> RenderableType:
        keys = [("q", "quit"), ("space", "pause"), ("+/-", "interval"), ("r", "reset peaks")]
        text = Text()
        for key, label in keys:
            text.append(f"  {key} ", style="reverse")
            text.append(f" {label}", style="grey62")
        return text

    # -- panels -------------------------------------------------------------

    def gpu_panel(self, snapshot: Snapshot, width: int) -> Panel:
        gpu = snapshot.gpu
        inner = max(20, width - 4)
        gauge_width = max(10, min(40, inner - 34))

        line = Text()
        line.append("Busy    ")
        line.append_text(bar(gpu.active_pct / 100, gauge_width))
        line.append(f" {gpu.active_pct:5.1f}%", style="bold white")
        if gpu.frequency_mhz:
            line.append(f"   {gpu.frequency_mhz:6.0f} MHz", style="cyan")
            if self.system.gpu_max_mhz:
                line.append(f" / {self.system.gpu_max_mhz:.0f}", style="grey62")
        rows: list[RenderableType] = [line]

        spark_width = max(10, inner - 14)
        trend = Text()
        trend.append(self.history.gpu.sparkline(spark_width, 100.0), style="cyan")
        trend.append(f"  avg {self.history.gpu.mean:4.0f}%", style="grey62")
        rows.append(trend)

        status = Text()
        status.append("Power   ", style="grey62")
        status.append(fmt_watts(snapshot.power.gpu_w), style="bold white")
        status.append(f"   peak {self.history.gpu_power.peak:.1f} W", style="grey62")
        if gpu.power_target_pct is not None and gpu.power_target_pct < 99.0:
            status.append(f"   power cap {gpu.power_target_pct:.0f}%", style="yellow")
        if gpu.throttle_events:
            status.append(f"   throttled x{gpu.throttle_events}", style="bright_red")
        rows.append(status)

        return Panel(Group(*rows), title="[bold]GPU", title_align="left", border_style="grey37")

    def memory_panel(self, snapshot: Snapshot, width: int) -> Panel:
        memory = snapshot.memory
        inner = max(24, width - 4)
        gauge_width = max(10, min(34, inner - 30))
        rows: list[RenderableType] = []

        used_pct = memory.gpu_used_pct
        head = Text()
        head.append("GPU / Metal working set", style="bold")
        rows.append(head)

        line = Text()
        line.append("  used  ")
        if used_pct is not None:
            line.append_text(bar(used_pct / 100, gauge_width))
            line.append(f" {used_pct:5.1f}%", style="bold white")
        else:
            line.append_text(bar(0, gauge_width, "grey35"))
        rows.append(line)

        detail = Text()
        detail.append(f"  {fmt_bytes(memory.gpu_used)}", style="bold white")
        detail.append(f" of {fmt_bytes(memory.gpu_budget)}", style="grey62")
        headroom = memory.gpu_headroom
        if headroom is not None:
            colour = "green" if headroom > 4 * GB else "bright_red"
            detail.append("   headroom ", style="grey62")
            detail.append(fmt_bytes(headroom), style=colour)
        rows.append(detail)
        rows.append(Text())

        rows.append(Text("System memory", style="bold"))
        system_pct = 100.0 * memory.used / memory.total if memory.total else 0.0
        line = Text()
        line.append("  used  ")
        line.append_text(bar(system_pct / 100, gauge_width))
        line.append(f" {system_pct:5.1f}%", style="bold white")
        rows.append(line)

        detail = Text()
        detail.append(f"  {fmt_bytes(memory.used)} of {fmt_bytes(memory.total)}", style="grey62")
        rows.append(detail)

        breakdown = Text()
        breakdown.append("  wired ", style="grey62")
        breakdown.append(fmt_bytes(memory.wired), style="white")
        breakdown.append("   compressed ", style="grey62")
        breakdown.append(
            fmt_bytes(memory.compressed),
            style="bright_red" if memory.compressed > 2 * GB else "white",
        )
        breakdown.append("   swap ", style="grey62")
        breakdown.append(
            fmt_bytes(memory.swap_used),
            style="bright_red" if memory.swap_used > 0 else "white",
        )
        rows.append(breakdown)

        return Panel(
            Group(*rows), title="[bold]Unified memory", title_align="left", border_style="grey37"
        )

    def power_panel(self, snapshot: Snapshot, width: int) -> Panel:
        power = snapshot.power
        inner = max(20, width - 4)
        gauge_width = max(8, min(24, inner - 22))

        rails = [
            ("GPU", power.gpu_w, "bright_magenta"),
            ("CPU", power.cpu_w, "cyan"),
            ("DRAM", power.dram_w, "blue"),
            ("ANE", power.ane_w, "grey62"),
        ]
        scale = max(10.0, self.history.gpu_power.peak, *(value or 0.0 for _, value, _ in rails))

        rows: list[RenderableType] = []
        for label, value, colour in rails:
            line = Text()
            line.append(f"{label:<5}", style="grey62")
            line.append(f"{fmt_watts(value)} ", style="bold white")
            line.append_text(bar((value or 0.0) / scale, gauge_width, colour))
            rows.append(line)

        rows.append(Text())
        chip = Text()
        chip.append("SoC  ", style="grey62")
        chip.append(fmt_watts(power.package_w), style="bold white")
        rows.append(chip)

        system = Text()
        system.append("Wall ", style="grey62")
        system.append(fmt_watts(power.system_w), style="bold white")
        if power.adapter_max_w:
            system.append(f" / {power.adapter_max_w:.0f} W", style="grey62")
        rows.append(system)

        if power.battery_pct is not None:
            battery = Text()
            battery.append("Batt ", style="grey62")
            battery.append(
                f"{power.battery_pct:3d}% ", style="yellow" if power.on_battery else "green"
            )
            battery.append("on battery" if power.on_battery else "charging/AC", style="grey62")
            rows.append(battery)

        return Panel(Group(*rows), title="[bold]Power", title_align="left", border_style="grey37")

    def bandwidth_panel(self, snapshot: Snapshot, width: int) -> Panel:
        bandwidth = snapshot.bandwidth
        inner = max(20, width - 4)
        total = bandwidth.dram_total_gbps
        peak = self.system.peak_memory_bandwidth_gbps

        line = Text()
        line.append("DRAM  ", style="grey62")
        if total is None:
            line.append("unavailable on this Mac", style="grey62")
        else:
            gauge_width = max(10, min(32, inner - 46))
            if peak:
                line.append_text(bar(total / peak, gauge_width))
                line.append(f" {total:6.1f} GB/s", style="bold white")
                line.append(f" of {peak:.0f}", style="grey62")
            else:
                line.append(f"{total:6.1f} GB/s", style="bold white")
            line.append(
                f"   read {bandwidth.dram_read_gbps or 0:.0f}"
                f"  write {bandwidth.dram_write_gbps or 0:.0f}",
                style="grey62",
            )
        rows: list[RenderableType] = [line]

        spark_width = max(10, inner - 20)
        trend = Text()
        trend.append(
            self.history.bandwidth.sparkline(spark_width, peak),
            style="blue",
        )
        trend.append(f"  peak {self.history.bandwidth.peak:.0f}", style="grey62")
        rows.append(trend)

        title = "[bold]Memory bandwidth[/] [grey62](estimated from controller histogram)"
        return Panel(Group(*rows), title=title, title_align="left", border_style="grey37")

    def process_panel(self, snapshot: Snapshot, width: int) -> Panel:
        table = Table.grid(padding=(0, 2), expand=True)
        table.add_column("pid", justify="right", width=6)
        table.add_column("process", ratio=3, no_wrap=True)
        table.add_column("runtime", width=10, no_wrap=True)
        table.add_column("memory", justify="right", width=9)
        table.add_column("cpu", justify="right", width=7)
        table.add_column("gpu", justify="center", width=3)

        table.add_row(
            *(
                Text(label, style="grey62 bold")
                for label in ("PID", "PROCESS", "RUNTIME", "MEMORY", "CPU", "GPU")
            )
        )

        if not snapshot.processes:
            table.add_row(Text(""), Text("no LLM runtime detected", style="grey50"), *[Text("")] * 4)
        for process in snapshot.processes:
            known = process.runtime is not None
            table.add_row(
                Text(str(process.pid), style="grey62"),
                Text(process.name, style="bold white" if known else "grey70"),
                Text(process.runtime or "-", style="cyan" if known else "grey50"),
                Text(fmt_bytes(process.memory), style="white"),
                Text(f"{process.cpu_pct:.0f}%", style="white"),
                Text("●" if process.uses_gpu else "", style="bright_magenta"),
            )

        return Panel(
            table, title="[bold]Processes", title_align="left", border_style="grey37"
        )

    def warning_panel(self, snapshot: Snapshot) -> RenderableType | None:
        if not snapshot.warnings:
            return None
        rows = [Text(f"! {message}", style="yellow") for message in snapshot.warnings]
        return Panel(Group(*rows), border_style="yellow", title="[bold yellow]Attention",
                     title_align="left")

    # -- composition --------------------------------------------------------

    def render(self, snapshot: Snapshot, width: int, height: int) -> RenderableType:
        blocks: list[RenderableType] = [self.header(snapshot, width), self.gpu_panel(snapshot, width)]

        wide = width >= 104
        if wide:
            split = Table.grid(expand=True, padding=(0, 0))
            split.add_column(ratio=3)
            split.add_column(ratio=2)
            split.add_row(
                self.memory_panel(snapshot, int(width * 0.6)),
                self.power_panel(snapshot, int(width * 0.4)),
            )
            blocks.append(split)
        else:
            blocks.append(self.memory_panel(snapshot, width))
            blocks.append(self.power_panel(snapshot, width))

        blocks.append(self.bandwidth_panel(snapshot, width))
        blocks.append(self.process_panel(snapshot, width))

        warning = self.warning_panel(snapshot)
        if warning is not None:
            blocks.append(warning)
        blocks.append(self.footer())
        return Group(*blocks)

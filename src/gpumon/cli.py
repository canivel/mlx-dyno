"""Command line entry point."""

from __future__ import annotations

import argparse
import json
import platform
import select
import sys
import termios
import time
import tty

from .model import GB

__version__ = "0.1.0"

_MIN_INTERVAL = 0.2
_MAX_INTERVAL = 60.0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="gpumon",
        description="GPU, power and unified-memory monitor for local LLM workloads "
        "on Apple Silicon. Reads Apple's own telemetry counters directly, so it "
        "never needs sudo.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "examples:\n"
            "  gpumon                        live dashboard\n"
            "  gpumon --once                 one snapshot, then exit\n"
            "  gpumon --json                 newline-delimited JSON for scripts\n"
            "  gpumon --csv run.csv -i 0.5   log a benchmark run at 2 Hz\n"
        ),
    )
    parser.add_argument(
        "-i", "--interval", type=float, default=1.0,
        help="seconds between samples (default: 1.0)",
    )
    parser.add_argument(
        "-n", "--count", type=int, default=0,
        help="stop after this many samples (default: run until interrupted)",
    )
    parser.add_argument("--once", action="store_true", help="print a single snapshot and exit")
    parser.add_argument(
        "--json", action="store_true",
        help="emit newline-delimited JSON instead of the dashboard",
    )
    parser.add_argument("--csv", metavar="PATH", help="also append every sample to a CSV file")
    parser.add_argument(
        "--peak-bandwidth", type=float, metavar="GBPS",
        help="this Mac's peak memory bandwidth, used to scale the bandwidth gauge",
    )
    parser.add_argument(
        "--procs", type=int, default=8, metavar="N",
        help="maximum processes to list (default: 8)",
    )
    parser.add_argument(
        "--min-proc-memory", type=float, default=1.0, metavar="GB",
        help="minimum memory for a non-LLM GPU process to be listed (default: 1.0)",
    )
    parser.add_argument("--no-color", action="store_true", help="disable colour output")
    parser.add_argument("--version", action="version", version=f"gpumon {__version__}")
    return parser


class KeyReader:
    """Single-keypress reader that doubles as the frame timer.

    Waiting for a key and waiting for the next sample are the same wait, so the
    dashboard stays responsive without polling. When stdin is not a terminal, or
    reaches EOF, this degrades to a plain sleep.
    """

    def __init__(self) -> None:
        self._fd: int | None = None
        self._saved: list | None = None

    def __enter__(self) -> "KeyReader":
        if sys.stdin is None or not sys.stdin.isatty():
            return self
        try:
            fd = sys.stdin.fileno()
            self._saved = termios.tcgetattr(fd)
            tty.setcbreak(fd)
            self._fd = fd
        except (termios.error, ValueError, OSError):
            self._fd = None
            self._saved = None
        return self

    def __exit__(self, *_exc) -> None:
        if self._fd is not None and self._saved is not None:
            termios.tcsetattr(self._fd, termios.TCSADRAIN, self._saved)
        self._fd = None
        self._saved = None

    def wait(self, timeout: float) -> str | None:
        """Return a keypress, or None if ``timeout`` elapsed first."""
        if self._fd is None:
            time.sleep(max(0.0, timeout))
            return None
        ready, _, _ = select.select([self._fd], [], [], max(0.0, timeout))
        if not ready:
            return None
        try:
            key = sys.stdin.read(1)
        except (OSError, ValueError):
            key = ""
        if not key:
            # EOF: stdin will stay readable forever, so stop selecting on it.
            self.__exit__()
            time.sleep(max(0.0, timeout))
            return None
        return key


def _require_apple_silicon() -> None:
    if platform.system() != "Darwin":
        raise SystemExit("gpumon only runs on macOS.")
    if platform.machine() != "arm64":
        raise SystemExit(
            "gpumon needs an Apple Silicon Mac; the counters it reads do not exist on Intel."
        )


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    _require_apple_silicon()

    if args.interval < _MIN_INTERVAL or args.interval > _MAX_INTERVAL:
        raise SystemExit(
            f"--interval must be between {_MIN_INTERVAL} and {_MAX_INTERVAL} seconds."
        )

    from .export import CsvLogger, plain_report, system_dict, write_json_line
    from .history import History
    from .sampler import Sampler

    try:
        sampler = Sampler(
            peak_bandwidth=args.peak_bandwidth,
            process_limit=max(1, args.procs),
            process_min_memory=int(args.min_proc_memory * GB),
        )
    except Exception as error:  # noqa: BLE001 - surface the reason, not a traceback
        raise SystemExit(f"could not start monitoring: {error}") from error

    logger = CsvLogger(args.csv) if args.csv else None

    try:
        if args.once:
            time.sleep(min(args.interval, 1.0))
            snapshot = sampler.sample()
            if logger:
                logger.write(snapshot)
            if args.json:
                payload = {"system": system_dict(sampler.system), **snapshot.to_dict()}
                print(json.dumps(payload, indent=2))
            else:
                print(plain_report(sampler.system, snapshot))
            return 0

        if args.json:
            return _run_json(sampler, args, logger, write_json_line, system_dict)

        return _run_dashboard(sampler, args, logger, History)
    finally:
        sampler.close()
        if logger:
            logger.close()


def _run_json(sampler, args, logger, write_json_line, system_dict) -> int:
    # Lead with one system record so a consumer knows what the samples describe.
    print(json.dumps({"type": "system", **system_dict(sampler.system)}, separators=(",", ":")))
    sys.stdout.flush()

    emitted = 0
    # Absolute deadlines rather than repeated sleeps, so the cadence neither
    # drifts nor collapses when a sample takes longer than usual.
    next_at = time.monotonic() + args.interval
    try:
        while True:
            time.sleep(max(0.0, next_at - time.monotonic()))
            next_at += args.interval
            snapshot = sampler.sample()
            if logger:
                logger.write(snapshot)
            write_json_line(snapshot)
            emitted += 1
            if args.count and emitted >= args.count:
                return 0
    except KeyboardInterrupt:
        return 0


def _run_dashboard(sampler, args, logger, History) -> int:
    from rich.console import Console
    from rich.live import Live

    from .ui import Dashboard

    console = Console(no_color=args.no_color, highlight=False)
    history = History()
    dashboard = Dashboard(sampler.system, history, interval=args.interval)

    # The first delta covers the window since the subscription was created, so
    # give it a moment of real elapsed time before drawing anything.
    time.sleep(min(args.interval, 0.5))
    snapshot = sampler.sample()
    history.push(snapshot)
    if logger:
        logger.write(snapshot)
    emitted = 1

    with KeyReader() as keys, Live(
        console=console, screen=True, refresh_per_second=8, transient=False
    ) as live:
        next_at = time.monotonic() + dashboard.interval
        try:
            while True:
                width, height = console.size
                live.update(dashboard.render(snapshot, width, height))
                if args.count and emitted >= args.count:
                    return 0

                key = keys.wait(next_at - time.monotonic())
                if key is not None:
                    if key in ("q", "Q", "\x03"):
                        return 0
                    if key == " ":
                        dashboard.paused = not dashboard.paused
                    elif key in ("+", "="):
                        dashboard.interval = min(_MAX_INTERVAL, dashboard.interval * 2)
                        next_at = time.monotonic() + dashboard.interval
                    elif key in ("-", "_"):
                        dashboard.interval = max(_MIN_INTERVAL, dashboard.interval / 2)
                        next_at = time.monotonic() + dashboard.interval
                    elif key in ("r", "R"):
                        history = History()
                        dashboard.history = history
                    continue

                # Advance by whole intervals so sampling time does not stretch
                # the cadence; resynchronise if we have fallen a full period behind.
                next_at += dashboard.interval
                if next_at < time.monotonic():
                    next_at = time.monotonic() + dashboard.interval
                if dashboard.paused:
                    continue
                snapshot = sampler.sample()
                history.push(snapshot)
                if logger:
                    logger.write(snapshot)
                emitted += 1
        except KeyboardInterrupt:
            return 0


if __name__ == "__main__":
    sys.exit(main())

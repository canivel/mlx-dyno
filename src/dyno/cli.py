"""`dyno` — one entry point for both halves of the tool.

    dyno serve --model <path>    run a model, and report how fast it runs
    dyno top                     watch the GPU, power and memory underneath

`serve` needs MLX, which is a heavy dependency and pointless on a machine that
is only monitoring; it is an optional extra, imported lazily and with a useful
message if it is missing.
"""

from __future__ import annotations

import sys

from . import __version__

USAGE = f"""\
MLX Dyno {__version__} — real metrics for local LLMs on Apple Silicon

usage: dyno <command> [options]

commands:
  serve    run an MLX model and expose its generation metrics
           (Prometheus /metrics and JSON /stats)
  top      live dashboard of GPU, power, unified memory and bandwidth

  dyno serve --help    every mlx_lm.server flag, plus the metrics endpoints
  dyno top --help      intervals, JSON and CSV output

examples:
  dyno serve --model mlx-community/Qwen3-8B-4bit --port 8971
  dyno top
  dyno top --csv run.csv -i 0.5
"""

SERVE_MISSING = """\
`dyno serve` needs MLX, which is not installed.

    pip install 'mlx-dyno[serve]'

`dyno top` works without it.
"""


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)

    if not argv or argv[0] in ("-h", "--help", "help"):
        print(USAGE, end="")
        return 0
    if argv[0] in ("-V", "--version", "version"):
        print(f"MLX Dyno {__version__}")
        return 0

    command, rest = argv[0], argv[1:]

    if command == "serve":
        try:
            from .serve.cli import main as serve_main
        except ImportError:
            print(SERVE_MISSING, file=sys.stderr, end="")
            return 1
        return serve_main(rest)

    if command == "top":
        from .monitor.cli import main as monitor_main

        return monitor_main(rest)

    print(f"dyno: unknown command {command!r}\n", file=sys.stderr)
    print(USAGE, end="", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

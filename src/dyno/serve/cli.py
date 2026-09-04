"""`dyno serve` entry point.

This is not a fork of `mlx_lm.server`. It imports it, swaps two classes for
instrumented subclasses, and hands control back -- so every flag, and every
future improvement to mlx_lm's batching and caching, keeps working. The only
additions are the timing hooks and two new endpoints.
"""

from __future__ import annotations

import sys
import time
from typing import Any

from .instrument import InstrumentedAPIHandler, InstrumentedResponseGenerator, registry

from .. import __version__

BANNER = """\
MLX Dyno {version}  ·  serving with live metrics
  OpenAI API   http://{host}:{port}/v1
  Metrics      http://{host}:{port}/metrics   (Prometheus)
  Stats        http://{host}:{port}/stats     (JSON)
"""


MLX_MISSING = """\
`dyno serve` needs MLX, which is not installed.

    pip install 'mlx-dyno[serve]'

`dyno top` works without it.
"""


class UnsupportedMLXLM(RuntimeError):
    pass


def _patch(server_module: Any) -> None:
    """Swap in the instrumented classes.

    Each seam is checked before use: if a future mlx_lm reshapes the server,
    this should fail loudly at start-up rather than silently serve without
    metrics.
    """
    required = ("ResponseGenerator", "APIHandler", "_run_http_server", "ModelProvider", "main")
    missing = [name for name in required if not hasattr(server_module, name)]
    if missing:
        raise UnsupportedMLXLM(
            "This mlx_lm build is missing "
            + ", ".join(missing)
            + ". MLX Dyno needs mlx-lm >= 0.28; upgrade with `pip install -U mlx-lm`."
        )

    # `run()` looks this up on the module at call time, so replacing it works.
    server_module.ResponseGenerator = InstrumentedResponseGenerator

    # `_run_http_server` binds its handler as a default argument, so the module
    # global cannot be swapped; wrap the function instead.
    original_run_http = server_module._run_http_server

    def run_http(host, port, response_generator, *args, **kwargs):
        kwargs["handler_class"] = InstrumentedAPIHandler
        return original_run_http(host, port, response_generator, *args, **kwargs)

    server_module._run_http_server = run_http

    # Time model loading and record which model is resident.
    provider = server_module.ModelProvider
    original_load = provider.load

    def load(self, model_path, *args, **kwargs):
        started = time.perf_counter()
        result = original_load(self, model_path, *args, **kwargs)
        elapsed = time.perf_counter() - started
        # `load` is also called for an already-resident model, which returns
        # instantly; reporting that as the load time would be misleading.
        registry.note_model_loaded(
            name=str(model_path), load_seconds=elapsed if elapsed > 0.05 else None
        )
        return result

    provider.load = load


def _announce(argv: list[str]) -> None:
    """Print where the endpoints live, before mlx_lm's own logging starts."""
    host, port = "127.0.0.1", "8080"
    for index, argument in enumerate(argv):
        if argument == "--host" and index + 1 < len(argv):
            host = argv[index + 1]
        elif argument.startswith("--host="):
            host = argument.split("=", 1)[1]
        elif argument == "--port" and index + 1 < len(argv):
            port = argv[index + 1]
        elif argument.startswith("--port="):
            port = argument.split("=", 1)[1]
    print(BANNER.format(version=__version__, host=host, port=port), flush=True)


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)

    try:
        import mlx_lm.server as server_module
    except ImportError:
        print(MLX_MISSING, file=sys.stderr, end="")
        return 1

    try:
        _patch(server_module)
    except UnsupportedMLXLM as error:
        print(str(error), file=sys.stderr)
        return 1

    if "--help" not in argv and "-h" not in argv:
        _announce(argv)

    # mlx_lm's main() reads sys.argv directly.
    sys.argv = [sys.argv[0] + " serve"] + argv
    try:
        server_module.main()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

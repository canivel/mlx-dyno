"""`dyno ps`, `dyno run`, `dyno stop` — the small commands that make the rest usable."""

from __future__ import annotations

import argparse
import json
import signal
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from typing import Any

# lsof lives in /usr/sbin, which a subprocess PATH often omits.
_LSOF = shutil.which("lsof") or "/usr/sbin/lsof"


def _is_router(port: int) -> bool:
    """A router answers /routes; a model server does not."""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/routes", timeout=1.5) as response:
            return response.status == 200
    except (urllib.error.URLError, OSError):
        return False


def _servers(include_router: bool = False) -> list[dict[str, Any]]:
    """Every local model server, via the router's own discovery."""
    from .router.backends import DEFAULT_PORTS, discover

    found = [backend.describe() for backend in discover(DEFAULT_PORTS)]
    if include_router:
        return found
    return [entry for entry in found if not _is_router(entry["port"])]


def _pid_on_port(port: int) -> int | None:
    try:
        listing = subprocess.run(
            [_LSOF, "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-Fp"],
            capture_output=True, text=True, timeout=6,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in listing.splitlines():
        if line.startswith("p"):
            try:
                return int(line[1:])
            except ValueError:
                return None
    return None


def ps(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="dyno ps", description="Model servers that are running.")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    servers = _servers()
    if args.json:
        print(json.dumps(servers, indent=2))
        return 0
    if not servers:
        print("Nothing running. Start a model with `dyno serve --model <path>`.")
        return 1

    print(f"{'MODEL':<40}{'PORT':>7}{'TOK/S':>9}{'ACTIVE':>8}  PID")
    for server in servers:
        pid = _pid_on_port(server["port"])
        rate = server.get("tokens_per_second")
        print(
            f"{server['name'][:39]:<40}"
            f"{server['port']:>7}"
            f"{(f'{rate:.1f}' if rate else '—'):>9}"
            f"{server.get('active_requests', 0):>8}"
            f"  {pid if pid else '—'}"
        )
    return 0


def stop(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="dyno stop", description="Stop a model server.")
    parser.add_argument("port", nargs="?", type=int,
                        help="the port to stop; omit with --all")
    parser.add_argument("--all", action="store_true", help="stop every model server")
    args = parser.parse_args(argv)

    if not args.all and args.port is None:
        parser.error("give a port, or --all")

    targets = [s["port"] for s in _servers()] if args.all else [args.port]
    stopped = 0
    for port in targets:
        pid = _pid_on_port(port)
        if pid is None:
            print(f"nothing listening on :{port}")
            continue
        try:
            import os

            os.kill(pid, signal.SIGTERM)
            stopped += 1
            print(f"stopped :{port} (pid {pid})")
        except (ProcessLookupError, PermissionError) as error:
            print(f"could not stop :{port}: {error}", file=sys.stderr)
    return 0 if stopped else 1


def run(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="dyno run", description="One prompt, one answer, with the numbers.",
    )
    parser.add_argument("prompt", nargs="*", help="the prompt (or read from stdin)")
    parser.add_argument("--port", type=int, help="a specific server; default is the first found")
    parser.add_argument("--model", help="model id, if the server needs telling")
    parser.add_argument("--max-tokens", type=int, default=512)
    parser.add_argument("--temperature", type=float, default=0.7)
    parser.add_argument("--seed", type=int)
    parser.add_argument("--no-thinking", action="store_true",
                        help="ask a reasoning model to answer directly")
    parser.add_argument("--quiet", action="store_true", help="just the text")
    args = parser.parse_args(argv)

    prompt = " ".join(args.prompt).strip() or sys.stdin.read().strip()
    if not prompt:
        parser.error("no prompt given")

    port = args.port
    model = args.model
    if port is None or model is None:
        servers = _servers()
        if not servers:
            print("Nothing running. Start a model with `dyno serve --model <path>`.",
                  file=sys.stderr)
            return 1
        chosen = next((s for s in servers if s["port"] == port), servers[0])
        port = port or chosen["port"]
        model = model or chosen["model_id"]

    body: dict[str, Any] = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": args.max_tokens,
        "temperature": args.temperature,
    }
    if args.seed is not None:
        body["seed"] = args.seed
    if args.no_thinking:
        body["chat_template_kwargs"] = {"enable_thinking": False}

    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"}, method="POST",
    )
    started = time.time()
    try:
        with urllib.request.urlopen(request, timeout=1800) as response:
            payload = json.loads(response.read().decode())
    except (urllib.error.URLError, OSError, ValueError) as error:
        print(f"request failed: {error}", file=sys.stderr)
        return 1
    elapsed = time.time() - started

    message = (payload.get("choices") or [{}])[0].get("message") or {}
    if reasoning := message.get("reasoning"):
        if not args.quiet:
            print(f"\033[2m{reasoning.strip()}\033[0m\n", file=sys.stderr)
    print(message.get("content") or "")

    if args.quiet:
        return 0

    usage = payload.get("usage") or {}
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/stats", timeout=3) as response:
            live = (json.loads(response.read().decode()).get("live") or {})
    except (urllib.error.URLError, OSError, ValueError):
        live = {}

    rate = live.get("last_decode_tokens_per_second")
    ttft = live.get("last_time_to_first_token")
    parts = [
        f"{usage.get('completion_tokens', 0)} tokens",
        f"{elapsed:.1f}s",
    ]
    if rate:
        parts.append(f"{rate:.1f} tok/s")
    if ttft:
        parts.append(f"{ttft:.2f}s to first token")
    print(f"\n\033[2m{'  ·  '.join(parts)}\033[0m", file=sys.stderr)
    return 0

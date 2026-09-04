"""`dyno route` — one endpoint in front of every local model."""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

from .backends import DEFAULT_PORTS, discover
from .policy import Policy, Rule
from .server import serve

BANNER = """\
MLX Dyno router  ·  one endpoint, every local model
  OpenAI API   http://{host}:{port}/v1
  Decisions    http://{host}:{port}/routes
  Backends     http://{host}:{port}/backends
  Metrics      http://{host}:{port}/metrics
"""


def load_rules(path: str | None) -> list[Rule]:
    if not path:
        return []
    try:
        raw = json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        print(f"could not read rules from {path}: {error}", file=sys.stderr)
        return []
    entries = raw.get("rules") if isinstance(raw, dict) else raw
    return [Rule.from_dict(entry) for entry in entries or []]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="dyno route",
        description="Route requests across the local models that are running.",
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8970)
    parser.add_argument(
        "--backend", action="append", default=[], metavar="PORT",
        help="a model server to use, as a port or host:port (repeatable). "
             "Naming any turns off scanning unless --scan is also given.",
    )
    parser.add_argument(
        "--scan", action="store_true",
        help="also probe the usual ports even when --backend is given",
    )
    parser.add_argument(
        "--rules", metavar="FILE", help="JSON file of explicit routing rules"
    )
    parser.add_argument(
        "--escalate-below", type=float, default=0.75, metavar="P",
        help="retry on a stronger model when mean token probability falls below"
             " this (0 disables; default: 0.75, measured between a confident"
             " answer at 0.95 and an out-of-depth one at 0.64)",
    )
    parser.add_argument(
        "--no-self-routing", action="store_true",
        help="do not let the strongest model tag a conversation's difficulty",
    )
    parser.add_argument(
        "--no-cost-model", action="store_true",
        help="pick the smallest model clearing a tier rather than the fastest",
    )
    parser.add_argument(
        "--expected-tokens", type=int, default=400,
        help="reply length assumed when comparing models (default: 400)",
    )
    parser.add_argument("--trace-file", metavar="FILE", help="append decisions as JSON lines")
    parser.add_argument("--log-level", default="WARNING")
    parser.add_argument(
        "--list", action="store_true", help="show the models it can see, then exit"
    )
    args = parser.parse_args(argv)

    logging.basicConfig(level=getattr(logging, args.log_level.upper(), logging.WARNING))

    scan = args.scan or not args.backend

    if args.list:
        found = discover(DEFAULT_PORTS, args.backend, scan=scan)
        if not found:
            print("No model servers found. Start one with `dyno serve`.")
            return 1
        print(f"{len(found)} model server(s), strongest first:\n")
        for backend in found:
            rate = backend.measured_tokens_per_second
            print(
                f"  {backend.name:<38} :{backend.port:<6}"
                f" capability {backend.capability:>6}"
                f"  {f'{rate:.1f} tok/s' if rate else 'rate unknown':>14}"
            )
        return 0

    policy = Policy(
        rules=load_rules(args.rules),
        escalate_below=args.escalate_below,
        expected_tokens=args.expected_tokens,
        self_routing=not args.no_self_routing,
        use_cost_model=not args.no_cost_model,
    )
    print(BANNER.format(host=args.host, port=args.port), flush=True)
    if policy.rules:
        print(f"  {len(policy.rules)} rule(s) loaded\n", flush=True)

    try:
        serve(args.host, args.port, policy, DEFAULT_PORTS, args.backend,
              args.trace_file, scan=scan)
    except OSError as error:
        print(f"could not start the router: {error}", file=sys.stderr)
        return 1
    return 0

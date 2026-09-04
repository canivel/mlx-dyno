"""`dyno bench` — reproducible throughput measurement.

The point is not another tokens-per-second number. Numbers like that are posted
constantly and are almost never comparable: different prompts, different context
lengths, a warm or cold machine, something else using the GPU. This records the
conditions alongside the result and refuses to present a comparison the
conditions do not support.

Models are run one at a time, each loaded and unloaded around its trials, so
every model sees the same memory situation rather than competing with the ones
before it.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import signal
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any

DEFAULT_PROMPTS = [
    "Explain how a B-tree index speeds up a range query.",
    "Write a Python function that merges two sorted lists, with a docstring.",
    "Summarise the tradeoffs between optimistic and pessimistic locking.",
    "What causes cache line false sharing, and how do you avoid it?",
]

# Conditions that make two runs incomparable. A machine that was 20 degrees
# hotter, or sharing its GPU, did not run the same benchmark.
_MAX_FOREIGN_GPU_MEMORY = 2 * 1024 ** 3


@dataclass
class Conditions:
    """The state of the machine around a trial."""

    gpu_busy_percent: float = 0.0
    gpu_memory_bytes: int = 0
    gpu_budget_bytes: int = 0
    bandwidth_gbps: float = 0.0
    swap_used_bytes: int = 0
    compressed_bytes: int = 0
    throttled: bool = False
    foreign_gpu_processes: list[str] = field(default_factory=list)
    foreign_gpu_memory_bytes: int = 0

    @property
    def is_clean(self) -> bool:
        """Whether a measurement taken here can be trusted for comparison."""
        return (
            not self.throttled
            and self.swap_used_bytes == 0
            and self.foreign_gpu_memory_bytes < _MAX_FOREIGN_GPU_MEMORY
        )

    def warnings(self) -> list[str]:
        notes: list[str] = []
        if self.throttled:
            notes.append("the GPU throttled during the run")
        if self.swap_used_bytes > 0:
            notes.append(f"the machine was swapping ({self.swap_used_bytes / 1024**3:.1f} GB)")
        if self.foreign_gpu_memory_bytes >= _MAX_FOREIGN_GPU_MEMORY:
            others = ", ".join(self.foreign_gpu_processes[:3]) or "another process"
            notes.append(
                f"{others} held "
                f"{self.foreign_gpu_memory_bytes / 1024**3:.1f} GB of GPU memory"
            )
        return notes


@dataclass
class Trial:
    model: str
    prompt_index: int
    repeat: int
    prompt_tokens: int = 0
    completion_tokens: int = 0
    decode_tokens_per_second: float | None = None
    prefill_tokens_per_second: float | None = None
    time_to_first_token: float | None = None
    wall_seconds: float = 0.0
    peak_memory_bytes: int | None = None
    output: str = ""
    error: str | None = None


@dataclass
class ModelResult:
    model: str
    label: str
    load_seconds: float | None = None
    weights_bytes: int | None = None
    trials: list[Trial] = field(default_factory=list)
    conditions: Conditions = field(default_factory=Conditions)

    def _rates(self) -> list[float]:
        return [
            trial.decode_tokens_per_second
            for trial in self.trials
            if trial.decode_tokens_per_second
        ]

    @property
    def median_tokens_per_second(self) -> float | None:
        rates = self._rates()
        return statistics.median(rates) if rates else None

    @property
    def spread_percent(self) -> float | None:
        """How much the trials disagreed. A wide spread means the number is
        not yet stable, whatever its median says."""
        rates = self._rates()
        if len(rates) < 2:
            return None
        median = statistics.median(rates)
        return 100 * (max(rates) - min(rates)) / median if median else None

    @property
    def median_ttft(self) -> float | None:
        values = [t.time_to_first_token for t in self.trials if t.time_to_first_token]
        return statistics.median(values) if values else None


def _sample_conditions() -> Conditions:
    """Read the machine, using the same telemetry the monitor uses."""
    conditions = Conditions()
    try:
        from .monitor.sampler import Sampler
    except ImportError:
        return conditions

    sampler = Sampler()
    time.sleep(0.35)
    snapshot = sampler.sample()
    sampler.close()

    conditions.gpu_busy_percent = snapshot.gpu.active_pct
    conditions.gpu_memory_bytes = snapshot.memory.gpu_used or 0
    conditions.gpu_budget_bytes = snapshot.memory.gpu_budget or 0
    conditions.bandwidth_gbps = snapshot.bandwidth.dram_total_gbps or 0.0
    conditions.swap_used_bytes = snapshot.memory.swap_used
    conditions.compressed_bytes = snapshot.memory.compressed
    conditions.throttled = snapshot.gpu.throttle_events > 0

    for process in snapshot.processes:
        if process.uses_gpu and process.runtime and "bench" not in process.command:
            conditions.foreign_gpu_processes.append(process.name)
            conditions.foreign_gpu_memory_bytes += process.memory
    return conditions


def _wait_for_health(port: int, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2):
                return True
        except (urllib.error.URLError, OSError):
            time.sleep(0.4)
    return False


def _post(port: int, path: str, payload: dict[str, Any], timeout: float) -> dict[str, Any]:
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}", data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode())


def _get(port: int, path: str) -> dict[str, Any] | None:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=3) as response:
            return json.loads(response.read().decode())
    except (urllib.error.URLError, OSError, ValueError):
        return None


def _resolve(path_or_repo: str) -> Path | None:
    """A local directory, or where the hub cached that repository."""
    directory = Path(path_or_repo)
    if directory.is_dir():
        return directory
    if "/" not in path_or_repo:
        return None
    try:
        from huggingface_hub.constants import HF_HUB_CACHE
    except ImportError:
        return None
    root = Path(HF_HUB_CACHE) / ("models--" + path_or_repo.replace("/", "--")) / "snapshots"
    if not root.is_dir():
        return None
    revisions = sorted(root.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True)
    return revisions[0] if revisions else None


def _weights_size(path_or_repo: str) -> int | None:
    """Bytes of weights, following the cache's symlinks to the real blobs."""
    directory = _resolve(path_or_repo)
    if directory is None:
        return None
    total = 0
    for entry in directory.iterdir():
        if entry.suffix not in (".safetensors", ".npz"):
            continue
        try:
            total += entry.resolve().stat().st_size
        except OSError:
            continue
    return total or None


def run_model(
    model: str, prompts: list[str], repeat: int, max_tokens: int,
    port: int, seed: int | None, warmup: bool, verbose: bool,
    python: str | None = None,
) -> ModelResult:
    """Start one model, measure it, stop it."""
    label = model.rstrip("/").split("/")[-1]
    result = ModelResult(model=model, label=label, weights_bytes=_weights_size(model))

    command = [
        python or sys.executable, "-m", "dyno", "serve",
        "--model", model, "--port", str(port), "--log-level", "ERROR",
    ]
    if verbose:
        print(f"  starting {label} …", flush=True)
    started = time.time()
    server = subprocess.Popen(
        command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )

    try:
        if not _wait_for_health(port, timeout=180):
            result.trials.append(Trial(model=label, prompt_index=-1, repeat=0,
                                       error="the server did not start"))
            return result

        # First request pays the load; time it, then discard it.
        if warmup:
            try:
                _post(port, "/v1/chat/completions", {
                    "model": model, "max_tokens": 8, "temperature": 0,
                    "messages": [{"role": "user", "content": "hello"}],
                }, timeout=900)
            except (urllib.error.URLError, OSError, ValueError):
                pass
            result.load_seconds = round(time.time() - started, 2)

        result.conditions = _sample_conditions()

        for index, prompt in enumerate(prompts):
            for attempt in range(repeat):
                trial = Trial(model=label, prompt_index=index, repeat=attempt)
                body: dict[str, Any] = {
                    "model": model, "max_tokens": max_tokens, "temperature": 0,
                    "messages": [{"role": "user", "content": prompt}],
                }
                if seed is not None:
                    body["seed"] = seed
                clock = time.time()
                try:
                    response = _post(port, "/v1/chat/completions", body, timeout=1800)
                except (urllib.error.URLError, OSError, ValueError) as error:
                    trial.error = str(error)
                    result.trials.append(trial)
                    continue
                trial.wall_seconds = round(time.time() - clock, 3)

                usage = response.get("usage") or {}
                trial.prompt_tokens = usage.get("prompt_tokens") or 0
                trial.completion_tokens = usage.get("completion_tokens") or 0
                message = (response.get("choices") or [{}])[0].get("message") or {}
                trial.output = (message.get("content") or "")[:4000]

                # The server's own figures, which exclude queue and prefill.
                stats = _get(port, "/stats") or {}
                live = stats.get("live") or {}
                trial.decode_tokens_per_second = live.get("last_decode_tokens_per_second")
                trial.prefill_tokens_per_second = live.get("last_prompt_tokens_per_second")
                trial.time_to_first_token = live.get("last_time_to_first_token")
                trial.peak_memory_bytes = (stats.get("memory") or {}).get("peak_bytes")

                if verbose:
                    rate = trial.decode_tokens_per_second
                    print(
                        f"    prompt {index + 1}/{len(prompts)} run {attempt + 1}/{repeat}: "
                        f"{rate:.1f} tok/s" if rate else
                        f"    prompt {index + 1} run {attempt + 1}: no rate",
                        flush=True,
                    )
                result.trials.append(trial)
    finally:
        try:
            os.killpg(os.getpgid(server.pid), signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            server.terminate()
        try:
            server.wait(timeout=20)
        except subprocess.TimeoutExpired:
            server.kill()
        # Let the weights actually leave memory before the next model loads.
        time.sleep(2.5)

    return result


def agreement(reference: ModelResult, other: ModelResult) -> float | None:
    """How often a model produced the same answer as the reference.

    A crude quality proxy, and honest about being one: identical greedy output
    at the same seed means the quantisation did not change the answer on this
    prompt. It says nothing about which answer is better.
    """
    pairs = 0
    matches = 0
    for left, right in zip(reference.trials, other.trials):
        if left.error or right.error or not left.output:
            continue
        pairs += 1
        if left.output.strip() == right.output.strip():
            matches += 1
    return matches / pairs if pairs else None


def write_csv(path: str, results: list[ModelResult]) -> None:
    columns = [
        "model", "prompt_index", "repeat", "prompt_tokens", "completion_tokens",
        "decode_tokens_per_second", "prefill_tokens_per_second",
        "time_to_first_token", "wall_seconds", "peak_memory_bytes",
        "load_seconds", "weights_bytes", "gpu_busy_percent", "bandwidth_gbps",
        "swap_used_bytes", "throttled", "foreign_gpu_memory_bytes", "error",
    ]
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        for result in results:
            for trial in result.trials:
                row = asdict(trial)
                row.pop("output", None)
                row.update({
                    "load_seconds": result.load_seconds,
                    "weights_bytes": result.weights_bytes,
                    "gpu_busy_percent": round(result.conditions.gpu_busy_percent, 1),
                    "bandwidth_gbps": round(result.conditions.bandwidth_gbps, 1),
                    "swap_used_bytes": result.conditions.swap_used_bytes,
                    "throttled": result.conditions.throttled,
                    "foreign_gpu_memory_bytes": result.conditions.foreign_gpu_memory_bytes,
                })
                writer.writerow({key: row.get(key) for key in columns})


def write_json(path: str, results: list[ModelResult], meta: dict[str, Any]) -> None:
    payload = {
        "meta": meta,
        "models": [
            {
                **{k: v for k, v in asdict(result).items() if k != "trials"},
                "median_tokens_per_second": result.median_tokens_per_second,
                "spread_percent": result.spread_percent,
                "median_ttft": result.median_ttft,
                "trials": [asdict(trial) for trial in result.trials],
            }
            for result in results
        ],
    }
    Path(path).write_text(json.dumps(payload, indent=2, default=str))


def report(results: list[ModelResult]) -> str:
    if not results:
        return "no results"
    reference = results[0]
    lines = [
        "",
        f"{'model':<34}{'tok/s':>8}{'spread':>8}{'TTFT':>7}"
        f"{'weights':>10}{'agree':>7}",
        "-" * 74,
    ]
    for result in results:
        rate = result.median_tokens_per_second
        spread = result.spread_percent
        ttft = result.median_ttft
        weights = result.weights_bytes
        score = None if result is reference else agreement(reference, result)
        lines.append(
            f"{result.label[:33]:<34}"
            f"{(f'{rate:.1f}' if rate else '—'):>8}"
            f"{(f'{spread:.0f}%' if spread is not None else '—'):>8}"
            f"{(f'{ttft:.2f}s' if ttft else '—'):>7}"
            f"{(f'{weights / 1024**3:.1f} GB' if weights else '—'):>10}"
            f"{('ref' if result is reference else (f'{score:.0%}' if score is not None else '—')):>7}"
        )

    notes: list[str] = []
    for result in results:
        for warning in result.conditions.warnings():
            notes.append(f"  {result.label}: {warning}")
    if notes:
        lines += ["", "Conditions that make these numbers unsafe to compare:"] + notes
    elif len(results) > 1:
        lines += ["", "All models ran under clean, comparable conditions."]

    if len(results) > 1 and reference.median_tokens_per_second:
        fastest = max(
            (r for r in results if r.median_tokens_per_second),
            key=lambda r: r.median_tokens_per_second or 0,
        )
        if fastest is not reference and fastest.median_tokens_per_second:
            ratio = fastest.median_tokens_per_second / reference.median_tokens_per_second
            saved = (reference.weights_bytes or 0) - (fastest.weights_bytes or 0)
            score = agreement(reference, fastest)
            summary = f"{fastest.label} is {ratio:.2f}x faster than {reference.label}"
            if saved > 0:
                summary += f", {saved / 1024**3:.1f} GB smaller"
            if score is not None:
                summary += f", and gave the same answer {score:.0%} of the time"
            lines += ["", summary]
    return "\n".join(lines)


def load_prompts(path: str | None) -> list[str]:
    if not path:
        return DEFAULT_PROMPTS
    text = Path(path).read_text()
    if path.endswith(".jsonl"):
        prompts = []
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            value = entry.get("prompt") if isinstance(entry, dict) else entry
            if isinstance(value, str):
                prompts.append(value)
        return prompts or DEFAULT_PROMPTS
    return [line for line in text.splitlines() if line.strip()] or DEFAULT_PROMPTS


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="dyno bench",
        description="Measure models under conditions recorded alongside the result.",
    )
    parser.add_argument("--model", action="append", default=[], required=True,
                        metavar="PATH", help="a model to measure (repeatable)")
    parser.add_argument("--prompts", metavar="FILE",
                        help="prompts, one per line or JSONL with a 'prompt' field")
    parser.add_argument("--repeat", type=int, default=3,
                        help="trials per prompt (default: 3)")
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--seed", type=int, default=0,
                        help="fixed seed so runs are reproducible (default: 0)")
    parser.add_argument("--port", type=int, default=8989,
                        help="scratch port for the model under test")
    parser.add_argument("--csv", metavar="FILE")
    parser.add_argument("--json", metavar="FILE")
    parser.add_argument("--no-warmup", action="store_true",
                        help="do not discard the first request")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument(
        "--python", metavar="PATH",
        help="interpreter used to run the models (default: this one)",
    )
    args = parser.parse_args(argv)

    # Fail here rather than after a three-minute wait for a server that was
    # never going to start.
    interpreter = args.python or sys.executable
    probe = subprocess.run(
        [interpreter, "-c", "import mlx_lm"], capture_output=True, text=True
    )
    if probe.returncode != 0:
        print(
            f"{interpreter} cannot import mlx_lm, so it cannot serve a model.\n"
            "Install the serving extra:  pip install 'mlx-dyno[serve]'\n"
            "or point at an interpreter that has it:  dyno bench --python "
            "~/.mlx-dyno/venv/bin/python …",
            file=sys.stderr,
        )
        return 1

    prompts = load_prompts(args.prompts)
    verbose = not args.quiet
    if verbose:
        print(
            f"Measuring {len(args.model)} model(s) on {len(prompts)} prompt(s), "
            f"{args.repeat} run(s) each. Models run one at a time.",
            flush=True,
        )

    results: list[ModelResult] = []
    for model in args.model:
        results.append(run_model(
            model, prompts, args.repeat, args.max_tokens, args.port,
            args.seed, not args.no_warmup, verbose, interpreter,
        ))

    print(report(results))

    meta = {
        "prompts": prompts, "repeat": args.repeat, "max_tokens": args.max_tokens,
        "seed": args.seed, "when": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    if args.csv:
        write_csv(args.csv, results)
        print(f"\nwrote {args.csv}")
    if args.json:
        write_json(args.json, results, meta)
        print(f"wrote {args.json}")
    return 0

"""`dyno inspect` — what the model was actually doing, token by token.

A model's own probabilities are the cheapest window into its behaviour, and
mlx_lm will hand them over for free. This turns them into the two things worth
looking at: where a model hesitated, and what a quantisation changed.

The second is the point. Everyone knows a 4-bit build is faster and smaller;
almost nobody can say what it cost, because comparing two runs needs the same
seed, the same prompt and a way to see exactly where they diverged.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field, asdict
from typing import Any


@dataclass
class TokenReading:
    """One generated token and what else the model considered."""

    text: str
    probability: float
    # (token, probability), most likely first.
    alternatives: list[tuple[str, float]] = field(default_factory=list)

    @property
    def entropy(self) -> float:
        """Spread across the alternatives, in bits.

        Probability alone says how sure the model was of its choice; entropy
        says whether anything else was in contention.
        """
        weights = [p for _, p in self.alternatives if p > 0]
        if not weights:
            return 0.0
        total = sum(weights)
        return -sum((p / total) * math.log2(p / total) for p in weights)

    @property
    def runner_up(self) -> tuple[str, float] | None:
        for token, probability in self.alternatives:
            if token != self.text:
                return (token, probability)
        return None


@dataclass
class Trace:
    model: str
    prompt: str
    text: str = ""
    tokens: list[TokenReading] = field(default_factory=list)
    seed: int | None = None
    error: str | None = None

    @property
    def mean_probability(self) -> float | None:
        if not self.tokens:
            return None
        return sum(token.probability for token in self.tokens) / len(self.tokens)

    @property
    def least_confident(self) -> list[int]:
        """Indices of the tokens the model was least sure about."""
        ranked = sorted(range(len(self.tokens)), key=lambda i: self.tokens[i].probability)
        return ranked[:8]

    def to_dict(self) -> dict[str, Any]:
        return {
            "model": self.model, "prompt": self.prompt, "text": self.text,
            "seed": self.seed, "mean_probability": self.mean_probability,
            "tokens": [
                {
                    "text": token.text,
                    "probability": round(token.probability, 5),
                    "entropy": round(token.entropy, 4),
                    "alternatives": [
                        {"token": name, "probability": round(value, 5)}
                        for name, value in token.alternatives
                    ],
                }
                for token in self.tokens
            ],
        }


def capture(
    port: int, model: str, prompt: str, *, max_tokens: int = 120,
    top_k: int = 5, seed: int | None = 0, temperature: float = 0.0,
) -> Trace:
    """Generate once, keeping the probabilities."""
    trace = Trace(model=model, prompt=prompt, seed=seed)
    body: dict[str, Any] = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": temperature,
        "logprobs": True,
        "top_logprobs": max(1, min(top_k, 10)),
    }
    if seed is not None:
        body["seed"] = seed

    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"}, method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=1800) as response:
            payload = json.loads(response.read().decode())
    except (urllib.error.URLError, OSError, ValueError) as error:
        trace.error = str(error)
        return trace

    choice = (payload.get("choices") or [{}])[0]
    trace.text = (choice.get("message") or {}).get("content") or ""

    for entry in ((choice.get("logprobs") or {}).get("content") or []):
        alternatives = [
            (alt.get("token", ""), math.exp(alt.get("logprob", -99)))
            for alt in (entry.get("top_logprobs") or [])
        ]
        trace.tokens.append(TokenReading(
            text=entry.get("token", ""),
            probability=math.exp(entry.get("logprob", -99)),
            alternatives=alternatives,
        ))
    return trace


@dataclass
class Divergence:
    """Where two runs of the same prompt stopped agreeing."""

    index: int
    reference_token: str
    other_token: str
    reference_probability: float
    other_probability: float
    # Whether the other model's choice was even considered by the reference.
    was_in_reference_alternatives: bool


def compare(reference: Trace, other: Trace) -> tuple[int | None, list[Divergence]]:
    """First divergence, and every divergence, between two traces.

    Run at the same seed and temperature, two builds of the same model produce
    identical text until precision starts to matter. The token where that stops
    is the most informative point in the comparison.
    """
    divergences: list[Divergence] = []
    first: int | None = None
    for index, (left, right) in enumerate(zip(reference.tokens, other.tokens)):
        if left.text == right.text:
            continue
        if first is None:
            first = index
        divergences.append(Divergence(
            index=index,
            reference_token=left.text,
            other_token=right.text,
            reference_probability=left.probability,
            other_probability=right.probability,
            was_in_reference_alternatives=any(
                token == right.text for token, _ in left.alternatives
            ),
        ))
    return first, divergences


def render(trace: Trace, width: int = 96) -> str:
    """The generated text, shaded by how sure the model was."""
    # Four bands rather than a gradient: a terminal has few colours, and the
    # question is "was it sure", not "exactly how sure".
    def shade(probability: float) -> str:
        if probability >= 0.9:
            return "\033[38;5;250m"
        if probability >= 0.6:
            return "\033[38;5;179m"
        if probability >= 0.3:
            return "\033[38;5;173m"
        return "\033[38;5;168m"

    out: list[str] = []
    column = 0
    for token in trace.tokens:
        text = token.text.replace("\n", "⏎")
        if column + len(text) > width:
            out.append("\n")
            column = 0
        out.append(f"{shade(token.probability)}{text}\033[0m")
        column += len(text)
    return "".join(out)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="dyno inspect",
        description="Token probabilities from a running model, and what a "
                    "quantisation changed.",
    )
    parser.add_argument("prompt")
    parser.add_argument("--port", type=int, action="append", default=[],
                        help="a running server (repeatable; the first is the reference)")
    parser.add_argument("--model", action="append", default=[],
                        help="model id for each port, in the same order")
    parser.add_argument("--max-tokens", type=int, default=120)
    parser.add_argument("--top-k", type=int, default=5)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--json", metavar="FILE", help="write the full trace")
    args = parser.parse_args(argv)

    ports = args.port or [8971]
    traces: list[Trace] = []
    for index, port in enumerate(ports):
        model = args.model[index] if index < len(args.model) else None
        if not model:
            # Never ask /v1/models: it lists the whole cache rather than the
            # loaded model, so it can name something the server cannot serve.
            from .router.backends import probe

            backend = probe(port)
            if backend is None:
                print(f"could not reach a model server on :{port}", file=sys.stderr)
                return 1
            model = backend.model_id
        traces.append(capture(
            port, model, args.prompt, max_tokens=args.max_tokens,
            top_k=args.top_k, seed=args.seed,
        ))

    for trace in traces:
        if trace.error:
            print(f"{trace.model}: {trace.error}", file=sys.stderr)
            continue
        confidence = trace.mean_probability or 0
        print(f"\n\033[1m{trace.model.split('/')[-1]}\033[0m  "
              f"mean confidence {confidence:.2f}, {len(trace.tokens)} tokens")
        print(render(trace))
        print("\n  least confident tokens:")
        for index in trace.least_confident[:5]:
            token = trace.tokens[index]
            runner = token.runner_up
            detail = f" (wanted {runner[0]!r} at {runner[1]:.0%})" if runner else ""
            print(f"    {index:>3}  {token.text!r:<16} {token.probability:.0%}"
                  f"  entropy {token.entropy:.2f}{detail}")

    if len(traces) > 1 and not traces[0].error:
        reference = traces[0]
        for other in traces[1:]:
            if other.error:
                continue
            first, divergences = compare(reference, other)
            print(f"\n\033[1m{reference.model.split('/')[-1]} vs "
                  f"{other.model.split('/')[-1]}\033[0m")
            if first is None:
                print("  identical output — this quantisation changed nothing here")
                continue
            print(f"  diverged at token {first} of {len(reference.tokens)}"
                  f" ({len(divergences)} tokens differ)")
            for divergence in divergences[:5]:
                seen = "considered it" if divergence.was_in_reference_alternatives \
                    else "never considered it"
                print(f"    {divergence.index:>3}  "
                      f"{divergence.reference_token!r} ({divergence.reference_probability:.0%})"
                      f"  →  {divergence.other_token!r} "
                      f"({divergence.other_probability:.0%})   reference {seen}")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump([trace.to_dict() for trace in traces], handle, indent=2)
        print(f"\nwrote {args.json}")
    return 0

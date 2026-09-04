"""Deciding which model answers a request.

Four mechanisms, in the order they get a say:

1. Explicit rules      — readable, predictable, no model call.
2. Self-routing        — the strongest model answers first and tags the
                         conversation's difficulty; later turns follow the tag.
3. Residency-aware cost— among the models that could serve a tier, prefer the
                         one that will actually finish first, accounting for
                         measured throughput, queue depth, and the load time a
                         non-resident model would cost.
4. Confidence escalation — if the cheap model's own token probabilities say it
                         was unsure, re-run on something stronger.

Every decision records the candidates it rejected and why, because a router you
cannot interrogate is one you end up disabling.
"""

from __future__ import annotations

import hashlib
import math
import re
import time
from dataclasses import dataclass, field
from typing import Any, Literal

from .backends import Backend

Tier = Literal["easy", "medium", "hard"]
TIERS: tuple[Tier, ...] = ("easy", "medium", "hard")

# What a tier expects of a model, as a capability score. Derived from the
# readable ranking in backends.py, so these are arguable rather than magic.
TIER_FLOOR: dict[Tier, float] = {"easy": 0.0, "medium": 2.5, "hard": 6.0}

# Loading a model that is not resident costs this per gigabyte of weights, on
# a machine reading from internal storage. Only used to decide whether a
# non-resident model is worth waking.
LOAD_SECONDS_PER_GB = 1.1


@dataclass
class Rule:
    """A user-written routing rule. The first one that matches wins."""

    name: str
    tier: Tier | None = None
    model: str | None = None
    # Any of these that are set must all match.
    contains: str | None = None
    matches: str | None = None
    longer_than: int | None = None
    shorter_than: int | None = None

    enabled: bool = True

    def describe(self) -> dict[str, Any]:
        return {
            "name": self.name, "tier": self.tier, "model": self.model,
            "contains": self.contains, "matches": self.matches,
            "longer_than": self.longer_than, "shorter_than": self.shorter_than,
            "enabled": self.enabled,
        }

    def applies(self, prompt: str) -> bool:
        if not self.enabled:
            return False
        if self.contains and self.contains.lower() not in prompt.lower():
            return False
        if self.matches and not re.search(self.matches, prompt, re.I):
            return False
        if self.longer_than is not None and len(prompt) <= self.longer_than:
            return False
        if self.shorter_than is not None and len(prompt) >= self.shorter_than:
            return False
        # A rule with no conditions would match everything by accident.
        return any(
            value is not None
            for value in (self.contains, self.matches, self.longer_than, self.shorter_than)
        )

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "Rule":
        return cls(
            name=raw.get("name", "rule"),
            tier=raw.get("tier"),
            model=raw.get("model"),
            contains=raw.get("contains"),
            matches=raw.get("matches"),
            longer_than=raw.get("longer_than"),
            shorter_than=raw.get("shorter_than"),
            enabled=raw.get("enabled", True),
        )


@dataclass
class Candidate:
    backend: Backend
    estimated_seconds: float
    resident: bool
    rejected_because: str | None = None

    def describe(self) -> dict[str, Any]:
        return {
            "model": self.backend.name,
            "capability": self.backend.capability,
            "tokens_per_second": self.backend.measured_tokens_per_second,
            "estimated_seconds": round(self.estimated_seconds, 2),
            "resident": self.resident,
            "rejected_because": self.rejected_because,
        }


@dataclass
class Decision:
    chosen: Backend
    mechanism: str
    reason: str
    tier: Tier | None = None
    candidates: list[Candidate] = field(default_factory=list)

    def describe(self) -> dict[str, Any]:
        return {
            "chosen": self.chosen.name,
            "chosen_model_id": self.chosen.model_id,
            "mechanism": self.mechanism,
            "reason": self.reason,
            "tier": self.tier,
            "candidates": [candidate.describe() for candidate in self.candidates],
        }


def conversation_key(messages: list[dict[str, Any]]) -> str:
    """A stable id for a conversation.

    The OpenAI API carries no conversation id, so the opening user message
    stands in for one: it is the same on every turn of the same thread.
    """
    first = next(
        (m.get("content") or "" for m in messages if m.get("role") == "user"), ""
    )
    return hashlib.sha1(str(first)[:400].encode()).hexdigest()[:16]


def mean_confidence(logprobs: list[dict[str, Any]] | None) -> float | None:
    """Average token probability of a completion.

    A model's own probabilities are the cheapest honest signal of whether it
    was guessing, and they cost nothing extra to ask for.

    Calibration, measured on Qwen1.5-0.5B: a question it handled well came back
    at 0.95, and one well beyond it at 0.64. The default threshold sits between
    those rather than at a round number.
    """
    if not logprobs:
        return None
    values = [entry.get("logprob") for entry in logprobs if entry.get("logprob") is not None]
    if not values:
        return None
    return sum(math.exp(value) for value in values) / len(values)


class Policy:
    def __init__(
        self,
        rules: list[Rule] | None = None,
        *,
        escalate_below: float = 0.75,
        expected_tokens: int = 400,
        self_routing: bool = True,
        use_cost_model: bool = True,
    ) -> None:
        self.rules = rules or []
        self.escalate_below = escalate_below
        self.expected_tokens = expected_tokens
        self.self_routing = self_routing
        self.use_cost_model = use_cost_model
        # conversation key -> (tier, when it was decided)
        self._tags: dict[str, tuple[Tier, float]] = {}

    # -- configuration ------------------------------------------------------

    def describe(self) -> dict[str, Any]:
        return {
            "escalate_below": self.escalate_below,
            "expected_tokens": self.expected_tokens,
            "self_routing": self.self_routing,
            "use_cost_model": self.use_cost_model,
            "rules": [rule.describe() for rule in self.rules],
            "tagged_conversations": len(self._tags),
        }

    def update(self, changes: dict[str, Any]) -> None:
        """Apply a partial configuration change.

        Everything here can change while the router is serving: a policy you
        must restart to adjust is one nobody adjusts.
        """
        if "escalate_below" in changes:
            self.escalate_below = max(0.0, min(1.0, float(changes["escalate_below"])))
        if "expected_tokens" in changes:
            self.expected_tokens = max(16, int(changes["expected_tokens"]))
        if "self_routing" in changes:
            self.self_routing = bool(changes["self_routing"])
        if "use_cost_model" in changes:
            self.use_cost_model = bool(changes["use_cost_model"])
        if "rules" in changes:
            self.rules = [Rule.from_dict(entry) for entry in changes["rules"] or []]
        if changes.get("forget_tags"):
            self._tags.clear()

    # -- tags ---------------------------------------------------------------

    def tag(self, key: str) -> Tier | None:
        entry = self._tags.get(key)
        return entry[0] if entry else None

    def remember(self, key: str, tier: Tier) -> None:
        self._tags[key] = (tier, time.time())

    def forget_stale(self, older_than: float = 6 * 3600) -> None:
        cutoff = time.time() - older_than
        self._tags = {k: v for k, v in self._tags.items() if v[1] >= cutoff}

    # -- cost ---------------------------------------------------------------

    def estimated_seconds(self, backend: Backend, resident: bool = True) -> float:
        """How long this backend would take to answer, near enough to compare.

        Queue depth matters as much as raw speed: a fast model with three
        requests ahead of it finishes after an idle slower one.
        """
        rate = backend.measured_tokens_per_second
        if not rate or rate <= 0:
            # No measurement yet: guess from size, which is what governs it.
            rate = max(120 / max(backend.parameters or 1, 0.5), 3)
        seconds = self.expected_tokens / rate
        seconds *= 1 + backend.active_requests
        if not resident:
            weights_gb = (backend.memory_bytes or 0) / 1024 ** 3
            seconds += LOAD_SECONDS_PER_GB * max(weights_gb, (backend.parameters or 4))
        return seconds

    # -- the decision -------------------------------------------------------

    def decide(
        self,
        prompt: str,
        messages: list[dict[str, Any]],
        backends: list[Backend],
        requested_model: str | None = None,
    ) -> Decision:
        if not backends:
            raise ValueError("no model servers are available")

        strongest = max(backends, key=lambda item: item.capability)

        # An explicit model in the request is an instruction, not a hint.
        if requested_model and requested_model not in ("auto", "router", "dyno"):
            for backend in backends:
                if requested_model in (backend.model_id, backend.name):
                    return Decision(
                        chosen=backend, mechanism="explicit",
                        reason=f"the request asked for {backend.name}",
                        candidates=[Candidate(backend, self.estimated_seconds(backend), True)],
                    )

        # 1. Rules.
        for rule in self.rules:
            if not rule.applies(prompt):
                continue
            if rule.model:
                match = next(
                    (b for b in backends if rule.model in (b.model_id, b.name)), None
                )
                if match:
                    return Decision(
                        chosen=match, mechanism="rule",
                        reason=f"rule “{rule.name}” names {match.name}",
                        candidates=[Candidate(match, self.estimated_seconds(match), True)],
                    )
            if rule.tier:
                return self._choose_in_tier(
                    rule.tier, backends,
                    mechanism="rule", reason=f"rule “{rule.name}” selects the {rule.tier} tier",
                )

        # 2. Self-routing: follow the tag this conversation already earned.
        key = conversation_key(messages)
        if self.self_routing:
            if tier := self.tag(key):
                return self._choose_in_tier(
                    tier, backends, mechanism="self-routing",
                    reason=f"this conversation was tagged {tier} by {strongest.name}",
                )
            # First turn: the strongest model answers, and tags it afterwards.
            return Decision(
                chosen=strongest, mechanism="self-routing",
                reason="first turn goes to the strongest model, which then tags the conversation",
                candidates=[Candidate(strongest, self.estimated_seconds(strongest), True)],
            )

        return self._choose_in_tier(
            "medium", backends, mechanism="default", reason="no rule or tag applied"
        )

    def _choose_in_tier(
        self, tier: Tier, backends: list[Backend], *, mechanism: str, reason: str
    ) -> Decision:
        floor = TIER_FLOOR[tier]
        eligible = [b for b in backends if b.capability >= floor] or backends

        candidates: list[Candidate] = []
        for backend in backends:
            seconds = self.estimated_seconds(backend)
            rejected = None
            if backend not in eligible:
                rejected = f"below the {tier} tier (capability {backend.capability})"
            candidates.append(Candidate(backend, seconds, True, rejected))

        if self.use_cost_model:
            # Cheapest model that still clears the tier: the point of routing.
            chosen = min(eligible, key=lambda b: self.estimated_seconds(b))
            detail = (
                f"fastest of {len(eligible)} model(s) clearing the {tier} tier"
                f" (~{self.estimated_seconds(chosen):.1f}s)"
            )
        else:
            chosen = min(eligible, key=lambda b: b.capability)
            detail = f"smallest model clearing the {tier} tier"

        for candidate in candidates:
            if candidate.backend is not chosen and candidate.rejected_because is None:
                candidate.rejected_because = "slower than the chosen model"

        return Decision(
            chosen=chosen, mechanism=mechanism, reason=f"{reason}; {detail}",
            tier=tier, candidates=candidates,
        )

    # -- escalation ---------------------------------------------------------

    def should_escalate(
        self, confidence: float | None, chosen: Backend, backends: list[Backend]
    ) -> Backend | None:
        """A stronger model to retry with, if the answer looked like a guess."""
        if confidence is None or confidence >= self.escalate_below:
            return None
        stronger = [b for b in backends if b.capability > chosen.capability]
        if not stronger:
            return None
        return min(stronger, key=lambda b: b.capability)

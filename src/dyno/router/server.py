"""The router's HTTP surface.

Speaks the OpenAI chat API, so anything that can talk to a local model server
can talk to the router without knowing it is one. Adds `/routes` for the
decision log, `/backends` for what it can see, and `/metrics`.
"""

from __future__ import annotations

import json
import logging
import threading
import time
import urllib.error
import urllib.request
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from .backends import Backend, discover
from .policy import Policy, conversation_key, mean_confidence

# How long a discovery result is trusted before re-probing. Probing is cheap
# but not free, and servers do not appear and vanish every second.
_DISCOVERY_TTL = 4.0
_TRACE_LIMIT = 300


class RouterState:
    """Shared state: what backends exist, the policy, and the decision log."""

    def __init__(
        self, policy: Policy, ports: tuple[int, ...], extra: list[str], scan: bool = True
    ) -> None:
        self.policy = policy
        self.ports = ports
        self.extra = extra
        self.scan = scan
        self.traces: deque[dict[str, Any]] = deque(maxlen=_TRACE_LIMIT)
        self.trace_file: str | None = None
        self.started_at = time.time()

        self._lock = threading.Lock()
        self._backends: list[Backend] = []
        self._discovered_at = 0.0
        self.requests_total = 0
        self.escalations_total = 0
        self.seconds_saved = 0.0

    def backends(self, force: bool = False) -> list[Backend]:
        with self._lock:
            fresh = time.time() - self._discovered_at < _DISCOVERY_TTL
            if fresh and not force and self._backends:
                return list(self._backends)
        found = discover(self.ports, self.extra, scan=self.scan)
        with self._lock:
            self._backends = found
            self._discovered_at = time.time()
            return list(found)

    def record(self, trace: dict[str, Any]) -> None:
        with self._lock:
            self.traces.appendleft(trace)
            self.requests_total += 1
            if trace.get("escalated_from"):
                self.escalations_total += 1
            self.seconds_saved += trace.get("seconds_saved") or 0.0
        if self.trace_file:
            try:
                with open(self.trace_file, "a", encoding="utf-8") as handle:
                    handle.write(json.dumps(trace, separators=(",", ":")) + "\n")
            except OSError:
                pass


def _post(url: str, payload: dict[str, Any], timeout: float = 900) -> dict[str, Any]:
    request = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode())


def _post_stream(url: str, payload: dict[str, Any], timeout: float = 900):
    request = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST",
    )
    return urllib.request.urlopen(request, timeout=timeout)


TAG_PROMPT = (
    "Classify how much model capability the following request needs. "
    "Answer with exactly one word: easy, medium, or hard.\n\n"
    "easy = short factual answers, simple rewriting, chit-chat\n"
    "medium = summarising, straightforward code, everyday reasoning\n"
    "hard = multi-step reasoning, tricky debugging, architecture, research\n\n"
    "Request:\n"
)


def tag_conversation(state: RouterState, backend: Backend, prompt: str, key: str) -> None:
    """Ask the strong model how hard this conversation is.

    Runs after the answer is already on its way back, so it costs the user
    nothing on the turn that pays for it.

    Thinking is turned off for this call. A reasoning model given a small token
    budget spends all of it thinking and returns empty content -- the answer is
    one word, so there is nothing to reason about anyway.
    """
    payload = {
        "model": backend.model_id,
        "messages": [{"role": "user", "content": TAG_PROMPT + prompt[:1500]}],
        "max_tokens": 8,
        "temperature": 0.0,
        "chat_template_kwargs": {"enable_thinking": False},
    }

    def classify(body: dict[str, Any]) -> str | None:
        result = _post(f"{backend.url}/v1/chat/completions", body, timeout=180)
        message = (result.get("choices") or [{}])[0].get("message", {}) or {}
        # Fall back to the reasoning field for templates that ignore the flag.
        for text in (message.get("content") or "", message.get("reasoning") or ""):
            for tier in ("easy", "medium", "hard"):
                if tier in text.lower():
                    return tier
        return None

    try:
        tier = classify(payload)
    except (urllib.error.URLError, OSError, ValueError, TimeoutError):
        # Not every chat template accepts the flag; try again without it.
        try:
            fallback = dict(payload)
            fallback.pop("chat_template_kwargs")
            fallback["max_tokens"] = 24
            tier = classify(fallback)
        except (urllib.error.URLError, OSError, ValueError, TimeoutError):
            return

    if tier:
        state.policy.remember(key, tier)  # type: ignore[arg-type]
        logging.info("tagged conversation %s as %s", key, tier)


class RouterHandler(BaseHTTPRequestHandler):
    state: RouterState  # injected

    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: Any) -> None:
        logging.debug("%s - %s", self.address_string(), format % args)

    # -- helpers ------------------------------------------------------------

    def _send_json(self, payload: Any, status: int = 200) -> None:
        body = json.dumps(payload, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, text: str, content_type: str = "text/plain") -> None:
        body = text.encode()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # -- GET ----------------------------------------------------------------

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        state = self.state

        if path == "/health":
            self._send_json({"status": "ok"})
        elif path == "/backends":
            self._send_json({"backends": [b.describe() for b in state.backends()]})
        elif path in ("/routes", "/v1/routes"):
            self._send_json({"routes": list(state.traces)})
        elif path == "/v1/models":
            self._send_json({
                "object": "list",
                "data": [{"id": "auto", "object": "model", "created": int(state.started_at)}]
                + [
                    {"id": b.model_id, "object": "model", "created": int(b.last_seen)}
                    for b in state.backends()
                ],
            })
        elif path == "/metrics":
            self._send_text(self._prometheus(), "text/plain; version=0.0.4")
        else:
            self._send_json({"error": "not found"}, status=404)

    def _prometheus(self) -> str:
        state = self.state
        lines = [
            "# TYPE dyno_router_requests_total counter",
            f"dyno_router_requests_total {state.requests_total}",
            "# TYPE dyno_router_escalations_total counter",
            f"dyno_router_escalations_total {state.escalations_total}",
            "# TYPE dyno_router_seconds_saved_total counter",
            f"dyno_router_seconds_saved_total {round(state.seconds_saved, 2)}",
            "# TYPE dyno_router_backends gauge",
            f"dyno_router_backends {len(state.backends())}",
        ]
        return "\n".join(lines) + "\n"

    # -- POST ---------------------------------------------------------------

    def do_POST(self) -> None:
        path = self.path.split("?", 1)[0]
        if path not in ("/v1/chat/completions", "/v1/completions"):
            self._send_json({"error": "not found"}, status=404)
            return

        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._send_json({"error": "invalid JSON"}, status=400)
            return

        state = self.state
        backends = state.backends()
        if not backends:
            self._send_json(
                {"error": "no model servers found. Start one with `dyno serve`."},
                status=503,
            )
            return

        messages = body.get("messages") or []
        prompt = next(
            (m.get("content") or "" for m in reversed(messages) if m.get("role") == "user"),
            "",
        )
        key = conversation_key(messages)
        is_first_turn = state.policy.tag(key) is None

        try:
            decision = state.policy.decide(
                prompt, messages, backends, requested_model=body.get("model")
            )
        except ValueError as error:
            self._send_json({"error": str(error)}, status=503)
            return

        started = time.time()
        stream = bool(body.get("stream"))
        strongest = max(backends, key=lambda b: b.capability)
        # Escalation needs the whole answer before it can judge it, so it only
        # applies when something stronger exists to escalate to.
        may_escalate = (
            state.policy.escalate_below > 0 and decision.chosen.capability < strongest.capability
        )

        trace: dict[str, Any] = {
            "id": f"{int(started * 1000)}",
            "time": started,
            "prompt": prompt[:240],
            "decision": decision.describe(),
            "streamed": stream,
        }

        try:
            if may_escalate:
                self._buffered(body, decision, backends, trace, state, stream)
            elif stream:
                self._streamed(body, decision, trace, state)
            else:
                self._plain(body, decision, trace, state)
        except (urllib.error.URLError, OSError, TimeoutError) as error:
            trace["error"] = str(error)
            state.record(trace)
            try:
                self._send_json({"error": str(error)}, status=502)
            except OSError:
                pass
            return

        trace["seconds"] = round(time.time() - started, 3)
        # What routing bought: the slowest eligible candidate is the model this
        # would have used without a policy.
        slowest = max(
            (c.estimated_seconds for c in decision.candidates), default=trace["seconds"]
        )
        trace["seconds_saved"] = max(0.0, round(slowest - trace["seconds"], 2))
        state.record(trace)

        if is_first_turn and state.policy.self_routing and prompt:
            threading.Thread(
                target=tag_conversation, args=(state, strongest, prompt, key), daemon=True
            ).start()

    # -- transports ---------------------------------------------------------

    def _payload(self, body: dict[str, Any], backend: Backend, **overrides: Any) -> dict[str, Any]:
        payload = dict(body)
        payload["model"] = backend.model_id
        payload.update(overrides)
        return payload

    def _plain(self, body, decision, trace, state) -> None:
        result = _post(
            f"{decision.chosen.url}/v1/chat/completions",
            self._payload(body, decision.chosen, stream=False),
        )
        trace["outcome"] = self._outcome(result)
        self._send_json(result)

    def _streamed(self, body, decision, trace, state) -> None:
        upstream = _post_stream(
            f"{decision.chosen.url}/v1/chat/completions",
            self._payload(body, decision.chosen, stream=True),
        )
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        tokens = 0
        for raw in upstream:
            if raw.startswith(b"data:"):
                tokens += 1
            self.wfile.write(raw)
            self.wfile.flush()
        trace["outcome"] = {"chunks": tokens}
        self.close_connection = True

    def _buffered(self, body, decision, backends, trace, state, stream) -> None:
        """Run the cheap model to completion, judge it, then answer or escalate.

        Tokens cannot be un-sent, so a reply that might be escalated cannot be
        streamed as it is produced. The cheap model is the fast one, which is
        what makes this affordable.
        """
        first = _post(
            f"{decision.chosen.url}/v1/chat/completions",
            self._payload(body, decision.chosen, stream=False, logprobs=True),
        )
        confidence = self._confidence(first)
        trace["confidence"] = None if confidence is None else round(confidence, 3)

        stronger = state.policy.should_escalate(confidence, decision.chosen, backends)
        result = first
        if stronger is not None:
            trace["escalated_from"] = decision.chosen.name
            trace["escalated_to"] = stronger.name
            trace["escalation_reason"] = (
                f"mean token probability {confidence:.2f} below "
                f"{state.policy.escalate_below:.2f}"
            )
            result = _post(
                f"{stronger.url}/v1/chat/completions",
                self._payload(body, stronger, stream=False),
            )

        trace["outcome"] = self._outcome(result)

        if not stream:
            self._send_json(result)
            return
        # Replay the finished answer as one SSE chunk, so a streaming client
        # still gets the shape it expects.
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        content = (result.get("choices") or [{}])[0].get("message", {}).get("content", "")
        chunk = {
            "id": result.get("id", "router"), "object": "chat.completion.chunk",
            "created": int(time.time()), "model": result.get("model", ""),
            "choices": [{"index": 0, "delta": {"role": "assistant", "content": content},
                         "finish_reason": None}],
        }
        done = dict(chunk)
        done["choices"] = [{"index": 0, "delta": {}, "finish_reason": "stop"}]
        for message in (chunk, done):
            self.wfile.write(f"data: {json.dumps(message)}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True

    @staticmethod
    def _confidence(result: dict[str, Any]) -> float | None:
        choice = (result.get("choices") or [{}])[0]
        logprobs = (choice.get("logprobs") or {}).get("content")
        return mean_confidence(logprobs)

    @staticmethod
    def _outcome(result: dict[str, Any]) -> dict[str, Any]:
        usage = result.get("usage") or {}
        return {
            "prompt_tokens": usage.get("prompt_tokens"),
            "completion_tokens": usage.get("completion_tokens"),
            "model": result.get("model"),
        }


def serve(
    host: str, port: int, policy: Policy, ports: tuple[int, ...],
    extra: list[str], trace_file: str | None = None, scan: bool = True,
) -> None:
    state = RouterState(policy, ports, extra, scan=scan)
    state.trace_file = trace_file
    handler = type("BoundRouterHandler", (RouterHandler,), {"state": state})
    server = ThreadingHTTPServer((host, port), handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()

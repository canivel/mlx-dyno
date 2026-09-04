"""`dyno pull` — download a model from the Hugging Face hub.

Progress is reported by watching the cache directory grow rather than by
hooking the downloader's internals. `huggingface_hub` has several transfer
backends (plain HTTP, `hf_transfer`, Xet) and they do not report progress the
same way; the bytes on disk are true regardless of which one is in use.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from pathlib import Path
from typing import Any

# Weights, tokenizer and config. Everything else in a repo is documentation.
ALLOW_PATTERNS = [
    "*.safetensors",
    "*.safetensors.index.json",
    "*.json",
    "*.txt",
    "*.model",
    "tokenizer*",
    "*.tiktoken",
]
IGNORE_PATTERNS = ["*.bin", "*.pth", "*.gguf", "*.onnx", "original/*", "*.md"]

_POLL_SECONDS = 0.4


# Captured before anything is redirected: the hub's progress bars and warnings
# also write to stdout, and they must not land in the middle of the JSON stream.
_REAL_STDOUT = sys.stdout


def _emit(payload: dict[str, Any]) -> None:
    """One JSON object per line, flushed, so a parent process can follow along."""
    _REAL_STDOUT.write(json.dumps(payload, separators=(",", ":")) + "\n")
    _REAL_STDOUT.flush()


def _quieten_hub() -> None:
    """Keep the hub's own chatter off stdout so the JSON stream stays clean."""
    try:
        from huggingface_hub.utils import disable_progress_bars

        disable_progress_bars()
    except Exception:
        pass
    sys.stdout = sys.stderr


def _cache_directory(repo_id: str) -> Path:
    from huggingface_hub.constants import HF_HUB_CACHE

    folder = "models--" + repo_id.replace("/", "--")
    return Path(HF_HUB_CACHE) / folder


def _directory_bytes(path: Path) -> int:
    total = 0
    if not path.exists():
        return 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                # Count real bytes: the cache stores blobs and symlinks to them.
                total += os.stat(os.path.join(root, name), follow_symlinks=False).st_size
            except OSError:
                continue
    return total


def _expected_bytes(repo_id: str) -> int | None:
    """Total download size, from the hub's file listing."""
    try:
        from huggingface_hub import HfApi

        info = HfApi().model_info(repo_id, files_metadata=True)
    except Exception:
        return None
    total = 0
    for sibling in getattr(info, "siblings", None) or []:
        name = getattr(sibling, "rfilename", "") or ""
        size = getattr(sibling, "size", None)
        if size and not any(name.endswith(x) for x in (".bin", ".pth", ".gguf", ".onnx")):
            total += size
    return total or None


def pull(repo_id: str, *, as_json: bool = False, revision: str | None = None) -> int:
    try:
        from huggingface_hub import snapshot_download
    except ImportError:
        message = "`dyno pull` needs huggingface_hub, which ships with MLX support."
        _emit({"type": "error", "message": message}) if as_json else print(message, file=sys.stderr)
        return 1

    if as_json:
        _quieten_hub()

    expected = _expected_bytes(repo_id)
    cache = _cache_directory(repo_id)
    already = _directory_bytes(cache)

    if as_json:
        _emit({"type": "start", "repo": repo_id, "total_bytes": expected,
               "existing_bytes": already})
    else:
        size = f"{expected / 1024 ** 3:.1f} GB" if expected else "unknown size"
        print(f"Downloading {repo_id} ({size})…", flush=True)

    outcome: dict[str, Any] = {}

    def worker() -> None:
        try:
            path = snapshot_download(
                repo_id,
                revision=revision,
                allow_patterns=ALLOW_PATTERNS,
                ignore_patterns=IGNORE_PATTERNS,
            )
            outcome["path"] = path
        except Exception as error:  # noqa: BLE001 - reported to the caller
            outcome["error"] = f"{type(error).__name__}: {error}"

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()

    last_emit = 0.0
    last_line = ""
    while thread.is_alive():
        time.sleep(_POLL_SECONDS)
        downloaded = _directory_bytes(cache)
        now = time.monotonic()
        if now - last_emit < _POLL_SECONDS:
            continue
        last_emit = now
        if as_json:
            _emit({"type": "progress", "downloaded_bytes": downloaded,
                   "total_bytes": expected})
        elif expected:
            percent = min(100.0, 100.0 * downloaded / expected)
            line = f"\r  {percent:5.1f}%  {downloaded / 1024 ** 3:6.2f} / {expected / 1024 ** 3:.2f} GB"
            if line != last_line:
                sys.stdout.write(line)
                sys.stdout.flush()
                last_line = line
    thread.join()

    if "error" in outcome:
        sys.stdout = _REAL_STDOUT
        if as_json:
            _emit({"type": "error", "message": outcome["error"]})
        else:
            print(f"\nfailed: {outcome['error']}", file=sys.stderr)
        return 1

    final = _directory_bytes(cache)
    sys.stdout = _REAL_STDOUT
    if as_json:
        _emit({"type": "done", "repo": repo_id, "path": outcome.get("path"),
               "downloaded_bytes": final})
    else:
        print(f"\n  done — {final / 1024 ** 3:.2f} GB at {outcome.get('path')}")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="dyno pull", description="Download an MLX model from the Hugging Face hub."
    )
    parser.add_argument("repo", help="repository id, e.g. mlx-community/Qwen3-8B-4bit")
    parser.add_argument("--revision", help="branch, tag or commit (default: main)")
    parser.add_argument("--json", action="store_true",
                        help="emit newline-delimited JSON progress")
    args = parser.parse_args(argv)
    try:
        return pull(args.repo, as_json=args.json, revision=args.revision)
    except KeyboardInterrupt:
        return 130

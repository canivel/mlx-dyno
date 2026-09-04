"""`dyno harness` — point other tools at your local models.

Everything here speaks the OpenAI API, so the work is not integration but
configuration: knowing which file each tool reads, what shape it wants, and
which endpoint to name. That knowledge is the whole feature.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

HOME = Path.home()


@dataclass
class Harness:
    key: str
    name: str
    description: str
    config_path: Path
    # Built lazily so the endpoint can be chosen at install time.
    render: Callable[[str, str], str]
    format: str = "json"
    notes: str = ""

    @property
    def is_configured(self) -> bool:
        if not self.config_path.exists():
            return False
        try:
            return "127.0.0.1" in self.config_path.read_text()
        except OSError:
            return False

    @property
    def is_installed(self) -> bool:
        """Whether the tool itself looks present, separately from its config."""
        return self.config_path.parent.exists() or shutil.which(self.key) is not None


def _continue_config(endpoint: str, model: str) -> str:
    return json.dumps({
        "models": [{
            "title": f"Dyno · {model}",
            "provider": "openai",
            "model": model,
            "apiBase": f"{endpoint}/v1",
            "apiKey": "not-needed",
        }],
        "tabAutocompleteModel": {
            "title": "Dyno autocomplete",
            "provider": "openai",
            "model": model,
            "apiBase": f"{endpoint}/v1",
            "apiKey": "not-needed",
        },
    }, indent=2)


def _aider_config(endpoint: str, model: str) -> str:
    return (
        f"openai-api-base: {endpoint}/v1\n"
        f"openai-api-key: not-needed\n"
        f"model: openai/{model}\n"
        "cache-prompts: true\n"
    )


def _zed_config(endpoint: str, model: str) -> str:
    return json.dumps({
        "language_models": {
            "openai": {
                "api_url": f"{endpoint}/v1",
                "available_models": [
                    {"name": model, "display_name": f"Dyno · {model}",
                     "max_tokens": 32768},
                ],
            }
        },
        "assistant": {
            "default_model": {"provider": "openai", "model": model},
            "version": "2",
        },
    }, indent=2)


def _cline_config(endpoint: str, model: str) -> str:
    return json.dumps({
        "cline.apiProvider": "openai",
        "cline.openAiBaseUrl": f"{endpoint}/v1",
        "cline.openAiApiKey": "not-needed",
        "cline.openAiModelId": model,
    }, indent=2)


def _shell_env(endpoint: str, model: str) -> str:
    return (
        "# Anything that reads the OpenAI environment variables.\n"
        f"export OPENAI_BASE_URL={endpoint}/v1\n"
        f"export OPENAI_API_BASE={endpoint}/v1\n"
        "export OPENAI_API_KEY=not-needed\n"
        f"export OPENAI_MODEL={model}\n"
    )


def registry() -> list[Harness]:
    return [
        Harness(
            key="continue", name="Continue",
            description="VS Code and JetBrains coding assistant",
            config_path=HOME / ".continue" / "config.json",
            render=_continue_config,
            notes="Reload the window after writing the config.",
        ),
        Harness(
            key="aider", name="Aider",
            description="terminal pair programmer that edits your repository",
            config_path=HOME / ".aider.conf.yml",
            render=_aider_config, format="yaml",
        ),
        Harness(
            key="zed", name="Zed",
            description="editor with a built-in assistant",
            config_path=HOME / ".config" / "zed" / "settings.json",
            render=_zed_config,
            notes="Zed merges settings; this writes only the model section, so "
                  "back the file up first if you have customised it.",
        ),
        Harness(
            key="cline", name="Cline",
            description="autonomous coding agent for VS Code",
            config_path=HOME / ".dyno" / "cline-settings.json",
            render=_cline_config,
            notes="Cline stores settings inside VS Code; paste these values "
                  "into its settings panel.",
        ),
        Harness(
            key="env", name="Shell environment",
            description="OpenAI environment variables for anything else",
            config_path=HOME / ".dyno" / "dyno.env",
            render=_shell_env, format="sh",
            notes="source ~/.dyno/dyno.env",
        ),
    ]


def find(key: str) -> Harness | None:
    return next((h for h in registry() if h.key == key), None)


def install(harness: Harness, endpoint: str, model: str, force: bool) -> tuple[bool, str]:
    contents = harness.render(endpoint, model)
    path = harness.config_path
    path.parent.mkdir(parents=True, exist_ok=True)

    if path.exists() and not force:
        # Never overwrite a file we did not write. Losing someone's editor
        # configuration to a convenience command is not a fair trade.
        backup = path.with_suffix(path.suffix + ".dyno-backup")
        if not backup.exists():
            try:
                backup.write_text(path.read_text())
            except OSError as error:
                return False, f"could not back up {path}: {error}"
        note = f"backed up the previous file to {backup.name}"
    else:
        note = ""

    try:
        path.write_text(contents)
    except OSError as error:
        return False, f"could not write {path}: {error}"
    return True, note


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="dyno harness",
        description="Point coding tools at the models you are running.",
    )
    sub = parser.add_subparsers(dest="command")

    listing = sub.add_parser("list", help="show what can be configured")
    listing.add_argument("--endpoint", default="http://127.0.0.1:8970")

    show = sub.add_parser("show", help="print a config without writing it")
    show.add_argument("harness")
    show.add_argument("--endpoint", default="http://127.0.0.1:8970")
    show.add_argument("--model", default="auto")

    setup = sub.add_parser("install", help="write the config")
    setup.add_argument("harness")
    setup.add_argument("--endpoint", default="http://127.0.0.1:8970",
                       help="the router (default) or a single model server")
    setup.add_argument("--model", default="auto",
                       help="'auto' lets the router choose (default)")
    setup.add_argument("--force", action="store_true",
                       help="overwrite without keeping a backup")

    args = parser.parse_args(argv)
    command = args.command or "list"

    if command == "list":
        print(f"Harnesses, pointed at {args.endpoint if hasattr(args, 'endpoint') else ''}\n")
        for harness in registry():
            state = "configured" if harness.is_configured else (
                "ready" if harness.is_installed else "not found"
            )
            print(f"  {harness.key:<10} {state:<12} {harness.name} — {harness.description}")
            print(f"  {'':<10} {harness.config_path}")
        print("\n  dyno harness install <name>       write the config")
        print("  dyno harness show <name>          print it without writing")
        return 0

    harness = find(getattr(args, "harness", ""))
    if harness is None:
        print(f"unknown harness. Try: {', '.join(h.key for h in registry())}")
        return 1

    if command == "show":
        print(harness.render(args.endpoint.rstrip("/"), args.model))
        return 0

    ok, note = install(harness, args.endpoint.rstrip("/"), args.model, args.force)
    if not ok:
        print(note)
        return 1
    print(f"wrote {harness.config_path}")
    if note:
        print(f"  {note}")
    if harness.notes:
        print(f"  {harness.notes}")
    print(f"  endpoint: {args.endpoint}/v1   model: {args.model}")
    return 0

#!/usr/bin/env python3
"""Prune installed companion runtimes that no configured launcher references."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import shutil
import stat
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Sequence


REVISION_RE = re.compile(r"^[0-9a-f]{40}$")
DEFAULT_ROOT = Path.home() / "Library" / "Application Support" / "Herdr" / "Backend"


class PruneError(RuntimeError):
    """An operational error while pruning runtimes."""


@dataclass(frozen=True)
class Runtime:
    """A direct-child runtime directory eligible for retention."""

    name: str
    path: Path
    mtime: float
    size: int


def _strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from _strings(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from _strings(item)


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return ""


def reference_strings(home: Path) -> list[str]:
    """Collect only the launcher and package-setting strings relevant to runtimes."""
    found: list[str] = []
    launch_agents = home / "Library" / "LaunchAgents"
    if launch_agents.is_dir():
        for path in launch_agents.glob("*.plist"):
            if not path.is_file():
                continue
            try:
                with path.open("rb") as handle:
                    payload = plistlib.load(handle)
            except (OSError, ValueError, plistlib.InvalidFileException):
                continue
            if not isinstance(payload, dict):
                continue
            arguments = payload.get("ProgramArguments")
            if isinstance(arguments, list):
                found.extend(value for value in arguments if isinstance(value, str))
            working = payload.get("WorkingDirectory")
            if isinstance(working, str):
                found.append(working)

    settings = home / ".pi" / "agent" / "settings.json"
    if settings.is_file():
        try:
            payload = json.loads(_read_text(settings))
        except json.JSONDecodeError:
            payload = None
        if isinstance(payload, dict):
            found.extend(_strings(payload.get("packages")))

    bin_dir = home / ".local" / "bin"
    if bin_dir.is_dir():
        for path in bin_dir.glob("herdr-*"):
            if path.is_file():
                found.append(_read_text(path))

    launcher = home / ".config" / "herdr-harness" / "run-herdr-harness.sh"
    if launcher.is_file():
        found.append(_read_text(launcher))
    return found


def candidates(root: Path) -> list[Runtime]:
    """List eligible direct-child runtime directories without following links."""
    if not root.is_dir():
        return []
    found: list[Runtime] = []
    try:
        children = list(root.iterdir())
    except OSError:
        return []
    for path in children:
        # Only exact revision directories are candidates; unrelated root children are never touched.
        if not REVISION_RE.fullmatch(path.name):
            continue
        # Runtime symlinks are never candidates, so deletion cannot escape the root.
        if path.is_symlink() or not path.is_dir():
            continue
        try:
            info = path.stat()
        except OSError:
            continue
        found.append(Runtime(path.name, path, info.st_mtime, directory_size(path)))
    return found


def directory_size(path: Path) -> int:
    """Return the regular-file size below a runtime without following symlinks."""
    total = 0
    for current, directories, files in os.walk(path, followlinks=False):
        current_path = Path(current)
        # Do not follow links inside a runtime; targets are outside retention accounting.
        directories[:] = [name for name in directories if not (current_path / name).is_symlink()]
        for name in files:
            child = current_path / name
            try:
                info = child.lstat()
            except OSError:
                continue
            if stat.S_ISREG(info.st_mode):
                total += info.st_size
    return total


def delete_runtime(runtime: Runtime, root_real: Path) -> bool:
    """Delete one re-validated runtime directory, returning whether it was removed."""
    path = runtime.path
    try:
        real_path = Path(os.path.realpath(path))
    except OSError:
        return False
    # Recheck after planning: a renamed or symlinked path must never escape the root.
    if path.parent.resolve(strict=False) != root_real:
        return False
    if not REVISION_RE.fullmatch(path.name) or path.is_symlink() or not path.is_dir() or real_path.parent != root_real:
        return False
    try:
        shutil.rmtree(path)
    except OSError as exc:
        raise PruneError(f"could not remove {path.name}: {exc}") from exc
    return True


def prune(root: Path, home: Path, keep: int, *, apply: bool) -> dict[str, Any]:
    """Build the pruning report and optionally remove the runtimes selected by it."""
    root_real = Path(os.path.realpath(root))
    runtimes = candidates(root)
    references = reference_strings(home)
    in_use = {runtime.name for runtime in runtimes if any(runtime.name in text for text in references)}
    retained = sorted((runtime for runtime in runtimes if runtime.name not in in_use), key=lambda item: item.mtime, reverse=True)
    newest = {runtime.name for runtime in retained[:max(0, keep)]}
    kept = in_use | newest
    removed = sorted((runtime for runtime in runtimes if runtime.name not in kept), key=lambda item: item.name)
    if apply:
        for runtime in removed:
            delete_runtime(runtime, root_real)
    return {
        "root": str(root),
        "inUse": sorted(in_use),
        "kept": sorted(kept),
        "removed": [runtime.name for runtime in removed],
        "freedBytes": sum(runtime.size for runtime in removed),
    }


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="installed runtime root")
    parser.add_argument("--home", type=Path, default=Path.home(), help="home directory to scan for references")
    parser.add_argument("--keep", type=int, default=2, help="newest unused runtimes to retain")
    parser.add_argument("--apply", action="store_true", help="delete runtimes instead of reporting a dry run")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        result = prune(args.root, args.home, max(0, args.keep), apply=args.apply)
    except PruneError as exc:
        print(f"herdr-prune-runtimes: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

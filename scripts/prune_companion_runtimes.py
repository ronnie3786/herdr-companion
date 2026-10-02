#!/usr/bin/env python3
"""Prune installed companion runtimes that no configured launcher references."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import plistlib
import re
import shutil
import stat
import sys
import tomllib
from xml.parsers.expat import ExpatError
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Sequence


REVISION_RE = re.compile(r"^[0-9a-f]{40}$")
RAW_REVISION_RE = re.compile(rb"(?<![0-9a-f])[0-9a-f]{40}(?![0-9a-f])")
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


def _raw_sha_strings(path: Path) -> list[str]:
    try:
        content = path.read_bytes()
    except OSError:
        return []
    return [match.group().decode("ascii") for match in RAW_REVISION_RE.finditer(content)]


def watcher_runtime_references(home: Path) -> tuple[list[str], list[dict[str, str]]]:
    """Read only the run manifests whose worker locks are still owned.

    Include standard state, explicit environment paths, and roots in private
    configuration and launch agents, so a detached worker protects its revision
    even after the companion launcher has switched to a newer revision.
    """
    roots = {home / '.local/share/herdr-companion/watchers'}
    configs = {home / '.config/herdr-companion/config.toml'}
    references, warnings = [], []

    def path(value, base=home):
        if not isinstance(value, str) or not value:
            return None
        if value == '~' or value.startswith('~/'):
            return home / value[2:] if value != '~' else home
        candidate = Path(value)
        return candidate if candidate.is_absolute() else base / candidate

    def environment(values, base=home):
        if not isinstance(values, dict):
            return
        for key, suffix in (('HERDR_HARNESS_WATCHERS_ROOT', ''), ('HERDR_STATE_DIR', 'watchers')):
            root = path(values.get(key), base)
            if root:
                roots.add(root / suffix if suffix else root)
        configured = path(values.get('HERDR_CONFIG'), base)
        if configured:
            configs.add(configured)

    environment(dict(os.environ))
    agents = home / 'Library/LaunchAgents'
    if agents.is_dir():
        for agent in agents.glob('*.plist'):
            try:
                with agent.open('rb') as handle:
                    document = plistlib.load(handle)
                if isinstance(document, dict):
                    environment(document.get('EnvironmentVariables', {}))
            except (OSError, ValueError, plistlib.InvalidFileException, ExpatError):
                pass  # Launcher parsing already reports these warnings.
    for config in list(configs):
        if not config.is_file():
            continue
        try:
            with config.open('rb') as handle:
                document = tomllib.load(handle)
            sections = [document, *document.get('machines', {}).values()]
            for section in sections:
                if not isinstance(section, dict):
                    continue
                environment(section.get('environment', {}), config.parent)
                root = path(section.get('watchers', {}).get('root'), config.parent)
                state = path(section.get('server', {}).get('state_dir'), config.parent)
                if root:
                    roots.add(root)
                if state:
                    roots.add(state / 'watchers')
        except (OSError, ValueError, AttributeError) as exc:
            warnings.append({'file': str(config), 'problem': 'Could not inspect Watcher runtime references: ' + type(exc).__name__})
    for root in roots:
        if not root.is_dir():
            continue
        for lock in root.glob('*/runs/*/runner.lock'):
            try:
                fd = os.open(lock, os.O_RDWR)
            except OSError:
                continue
            try:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    manifest = lock.parent / 'run.json'
                    try:
                        document = json.loads(manifest.read_text(encoding='utf-8'))
                        if isinstance(document.get('runtime_path'), str):
                            references.append(document['runtime_path'])
                    except (OSError, ValueError, AttributeError):
                        references.extend(_raw_sha_strings(manifest))
                        warnings.append({'file': str(manifest), 'problem': 'Live Watcher runner has an unreadable runtime manifest'})
            finally:
                os.close(fd)
    return references, warnings


def reference_strings(home: Path) -> tuple[list[str], list[dict[str, str]]]:
    """Collect only the launcher and package-setting strings relevant to runtimes."""
    found: list[str] = []
    warnings: list[dict[str, str]] = []
    launch_agents = home / "Library" / "LaunchAgents"
    if launch_agents.is_dir():
        for path in sorted(launch_agents.glob("*.plist")):
            if not path.is_file():
                continue
            try:
                with path.open("rb") as handle:
                    payload = plistlib.load(handle)
            except Exception as exc:
                found.extend(_raw_sha_strings(path))
                warnings.append({"file": str(path), "problem": str(exc) or type(exc).__name__})
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
    if settings.exists():
        try:
            payload = json.loads(settings.read_text(encoding="utf-8"))
        except Exception as exc:
            found.extend(_raw_sha_strings(settings))
            warnings.append({"file": str(settings), "problem": str(exc) or type(exc).__name__})
        else:
            if isinstance(payload, dict):
                found.extend(_strings(payload.get("packages")))

    bin_dir = home / ".local" / "bin"
    if bin_dir.is_dir():
        for path in bin_dir.glob("herdr-*"):
            if path.is_file():
                try:
                    found.append(path.read_text(encoding="utf-8"))
                except Exception as exc:
                    found.extend(_raw_sha_strings(path))
                    warnings.append({"file": str(path), "problem": str(exc) or type(exc).__name__})

    launcher = home / ".config" / "herdr-harness" / "run-herdr-harness.sh"
    if launcher.exists():
        try:
            found.append(launcher.read_text(encoding="utf-8"))
        except Exception as exc:
            found.extend(_raw_sha_strings(launcher))
            warnings.append({"file": str(launcher), "problem": str(exc) or type(exc).__name__})
    watcher_references, watcher_warnings = watcher_runtime_references(home)
    found.extend(watcher_references)
    warnings.extend(watcher_warnings)
    return found, warnings


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
    references, warnings = reference_strings(home)
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
        "warnings": sorted(warnings, key=lambda warning: warning["file"]),
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

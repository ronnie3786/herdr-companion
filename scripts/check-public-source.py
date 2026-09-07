#!/usr/bin/env python3
"""Check publishable Git content without echoing matching sensitive values."""
from __future__ import annotations

import argparse
import fnmatch
import json
from pathlib import Path
import re
import subprocess
import sys

PRIVATE_FILES = (
    "config.toml", "config.local.toml", "config.*.local.toml", ".env", ".env.*",
    "Local.xcconfig", "Local.entitlements", "HerdrBootstrap.plist", "*.p8", "*.p12",
    "*.pem", "*.key", "*.mobileprovision", "*.sqlite*", "*.db", "*.ipa",
)
RULES = {
    "personal home path": re.compile(rb"/(?:Users|home)/(?!developer(?:/|\b)|example(?:/|\b)|test(?:/|\b)|user(?:/|\b)|your-username(?:/|\b))[A-Za-z0-9_.-]+/"),
    "tailnet DNS literal": re.compile(rb"(?:[A-Za-z0-9-]+\.)+ts\.net\b"),
    "tailnet IP literal": re.compile(rb"\b100\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b"),
    "legacy runtime import": re.compile(rb"(?:from|import)\s+cmux_harness\b"),
    "legacy repository reference": re.compile(rb"cmux[-]orchestrator"),
    "legacy tool route": re.compile(rb"/api/orchestrator[-]v2"),
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "GitHub credential": re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})\b"),
}


def inspect(relative: str, content: bytes, extra=()) -> list[dict]:
    issues = []
    name = Path(relative).name
    if name != ".env.example" and any(fnmatch.fnmatch(name, pattern) for pattern in PRIVATE_FILES):
        issues.append({"file": relative, "category": "private configuration or runtime artifact"})
    for category, pattern in (*RULES.items(), *extra):
        for match in pattern.finditer(content):
            issues.append({"file": relative, "line": content[:match.start()].count(b"\n") + 1, "category": category})
    return issues


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staged", action="store_true", help="Inspect exact staged blobs, suitable for a pre-commit hook")
    parser.add_argument("--private-patterns", type=Path, help="Optional PRIVATE JSON array of additional regular expressions")
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[1]
    extra = []
    if args.private_patterns:
        patterns = json.loads(args.private_patterns.read_text())
        if not isinstance(patterns, list) or any(not isinstance(value, str) for value in patterns):
            parser.error("Private patterns must be a JSON array of strings")
        extra = [("private identifier", re.compile(value.encode(), re.I)) for value in patterns]
    command = ["git", "ls-files", "-z", "--cached"]
    if not args.staged:
        command += ["--others", "--exclude-standard"]
    try:
        output = subprocess.check_output(command, cwd=root, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        parser.error("Run this check from a Git checkout")
    files = sorted(set(value.decode() for value in output.split(b"\0") if value))
    staged_symlinks = set()
    if args.staged:
        entries = subprocess.check_output(["git", "ls-files", "--stage", "-z"], cwd=root)
        staged_symlinks = {entry.split(b"\t", 1)[1].decode() for entry in entries.split(b"\0") if entry.startswith(b"120000 ")}
    issues = []
    for relative in files:
        if args.staged:
            if relative in staged_symlinks:
                issues.append({"file": relative, "category": "source symlink requires review"})
                continue
            content = subprocess.check_output(["git", "show", ":" + relative], cwd=root)
        else:
            path = root / relative
            if path.is_symlink():
                issues.append({"file": relative, "category": "source symlink requires review"})
                continue
            if not path.is_file():
                continue
            content = path.read_bytes()
        issues.extend(inspect(relative, content, extra))
    print(json.dumps({"ok": not issues, "filesChecked": len(files), "findings": issues}, indent=2))
    return int(bool(issues))


if __name__ == "__main__":
    raise SystemExit(main())

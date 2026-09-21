"""Small, dependency-free unified diff reader used by PR Review."""
from __future__ import annotations

import re

_HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$")


def _path(value: str) -> str | None:
    value = value.split("\t", 1)[0]
    if value in {"/dev/null", "a/dev/null", "b/dev/null"}:
        return None
    return value[2:] if value.startswith(("a/", "b/")) else value


def parse_unified_diff(text: str, *, truncated: bool = False) -> list[dict]:
    """Return the public ``diff_file`` shape without interpreting source text."""
    files: list[dict] = []
    current: dict | None = None
    hunk: dict | None = None
    old_no = new_no = 0

    def finish() -> None:
        nonlocal current, hunk
        if current is not None:
            if not current["path"]:
                current["path"] = current["old_path"] or "unknown"
            files.append(current)
        current = hunk = None
    for raw in text.splitlines():
        if raw.startswith("diff --git "):
            finish()
            parts = raw.split(" ", 3)
            old, new = (_path(parts[2]), _path(parts[3])) if len(parts) == 4 else (None, None)
            current = {
                "path": new or old or "unknown",
                "old_path": old,
                "status": "modified",
                "additions": 0,
                "deletions": 0,
                "binary": False,
                "truncated": truncated,
                "hunks": [],
            }
            continue
        if current is None:
            continue
        if raw.startswith("new file mode "):
            current["status"] = "added"
        elif raw.startswith("deleted file mode "):
            current["status"] = "deleted"
        elif raw.startswith("rename from "):
            current["old_path"] = raw[12:]
            current["status"] = "renamed"
        elif raw.startswith("rename to "):
            current["path"] = raw[10:]
            current["status"] = "renamed"
        elif raw.startswith("Binary files ") or raw == "GIT binary patch":
            current["binary"] = True
            current["status"] = "binary"
        elif raw.startswith("--- "):
            current["old_path"] = _path(raw[4:])
        elif raw.startswith("+++ "):
            value = _path(raw[4:])
            if value is not None:
                current["path"] = value
        elif (match := _HUNK.match(raw)):
            old_no, old_lines, new_no, new_lines, header = match.groups()
            old_no, new_no = int(old_no), int(new_no)
            hunk = {
                "old_start": old_no,
                "old_lines": int(old_lines or 1),
                "new_start": new_no,
                "new_lines": int(new_lines or 1),
                "header": header.strip(),
                "lines": [],
            }
            current["hunks"].append(hunk)
        elif hunk is not None and raw and raw[0] in " +-":
            prefix, value = raw[0], raw[1:]
            if prefix == "+":
                hunk["lines"].append({"kind": "add", "old_number": None, "new_number": new_no, "text": value})
                current["additions"] += 1
                new_no += 1
            elif prefix == "-":
                hunk["lines"].append({"kind": "del", "old_number": old_no, "new_number": None, "text": value})
                current["deletions"] += 1
                old_no += 1
            elif prefix == " ":
                hunk["lines"].append({"kind": "context", "old_number": old_no, "new_number": new_no, "text": value})
                old_no += 1
                new_no += 1
    finish()
    return files


def line_window(text: str, start: int | None = None, end: int | None = None) -> dict:
    lines = text.splitlines()
    total = len(lines)
    start = max(1, min(total or 1, int(start or 1)))
    end = max(start, min(total, int(end or total))) if total else 0
    return {
        "start_line": start,
        "end_line": end,
        "total_lines": total,
        "text": "\n".join(lines[start - 1:end]) + ("\n" if start <= end and text.endswith("\n") else ""),
    }


def excerpt_for_selection(text: str, start: int, end: int, *, radius: int = 40, maximum: int = 12 * 1024) -> dict:
    result = line_window(text, max(1, start - radius), end + radius)
    encoded = result["text"].encode()
    if len(encoded) > maximum:
        result["text"] = encoded[:maximum].decode("utf-8", "ignore")
    return result

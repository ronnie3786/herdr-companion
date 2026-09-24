"""Conservative PR association using the feature request, never a whole transcript."""
from __future__ import annotations

import json
import re
import subprocess
from urllib.parse import urlsplit

from .first_mate_links import parse_github_pull_request

_TICKET = re.compile(r"(?<![A-Za-z0-9])([A-Z][A-Z0-9]{1,15}-[1-9][0-9]*)(?![A-Za-z0-9])", re.I)
_PR = re.compile(r"\b(?:PR|pull request)\s*#?\s*([1-9][0-9]*)\b", re.I)
_URL = re.compile(r"https?://[^\s<>\"'`)\]}]+")
_REFERENCE = re.compile(r"\b(?:example|historical|previous|related|dependency|background|unrelated|reference|references)\b", re.I)
_CREATED = re.compile(
    r"\b(?:created|opened|updated)\s+(?:(?:the|a|this)\s+)?"
    r"(?:PR\b|pull request\b|https://github\.com/)|\bPR for\b", re.I,
)


def repository_names(cwd: str) -> frozenset[str]:
    """Read only local Git configuration; never contact a remote or run a hook."""
    try:
        result = subprocess.run(["git", "-C", cwd, "config", "--local", "--get-regexp", r"^remote\..*\.url$"],
                                capture_output=True, text=True, timeout=2, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return frozenset()
    repositories = set()
    for line in result.stdout[:64 * 1024].splitlines():
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        url = parts[1]
        if url.startswith("git@github.com:"):
            path = url[len("git@github.com:"):]
        else:
            try:
                parsed = urlsplit(url)
            except ValueError:
                continue
            if parsed.hostname != "github.com":
                continue
            path = parsed.path.lstrip("/")
        path = path.rstrip("/").removesuffix(".git")
        if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", path):
            repositories.add(path.casefold())
    return frozenset(repositories)


class PullRequestContext:
    def __init__(self, title: str, goal: str, repositories: frozenset[str]):
        self.repositories = repositories
        # The title's ticket is primary; expanded goals often quote dependencies.
        self.tickets = {key.upper() for key in (_TICKET.findall(title) or _TICKET.findall(goal))}
        self.urls: set[str] = set()
        self.numbers: set[int] = set()
        for sentence in re.split(r"(?<=[.!?])\s+|[\n;]", title + "\n" + goal):
            if _REFERENCE.search(sentence):
                continue
            self.numbers.update(int(number) for number in _PR.findall(sentence))
            for candidate in _URL.findall(sentence):
                parsed = parse_github_pull_request(candidate.rstrip(".,;:!?"))
                if parsed:
                    self.urls.add(parsed["url"])

    def qualify(self, url: str, text: str = "", *, matched_ticket: str = "", allow_prose: bool = True) -> dict[str, str] | None:
        parsed = parse_github_pull_request(url)
        if parsed is None:
            return None
        if parsed["url"] in self.urls:
            return {}
        repository = (parsed["owner"] + "/" + parsed["repo"]).casefold()
        if repository not in self.repositories:
            return None
        if parsed["number"] in self.numbers:
            return {}
        # A named target takes precedence over looser ticket associations.
        if self.urls or self.numbers:
            return None
        if matched_ticket and matched_ticket.upper() in self.tickets:
            return {"matched_ticket": matched_ticket.upper()}
        # Structured gh output is assessed one PR at a time. A ticket elsewhere
        # in a search result, PR body, or dependency list cannot qualify this PR.
        try:
            data = json.loads(text)
        except (ValueError, TypeError):
            data = None
        entries = data if isinstance(data, list) else [data]
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            identity = parse_github_pull_request(entry.get("url"))
            if identity is None or identity["url"] != parsed["url"]:
                continue
            fields = " ".join(str(entry.get(name) or "") for name in ("title", "headRefName"))
            matching = self.tickets.intersection(key.upper() for key in _TICKET.findall(fields))
            if matching:
                return {"matched_ticket": sorted(matching)[0]}
        if not allow_prose or data is not None:
            return None
        # A direct delivery statement can identify the ticket's PR. Ordinary
        # mentions, tool logs and paragraphs containing several PRs are ambiguous.
        for paragraph in re.split(r"\n\s*\n", text):
            if not _CREATED.search(paragraph) or _REFERENCE.search(paragraph):
                continue
            urls = {p["url"] for candidate in _URL.findall(paragraph)
                    if (p := parse_github_pull_request(candidate.rstrip(".,;:!?")))}
            if urls != {parsed["url"]}:
                continue
            matching = self.tickets.intersection(key.upper() for key in _TICKET.findall(paragraph))
            if matching:
                return {"matched_ticket": sorted(matching)[0]}
        return None

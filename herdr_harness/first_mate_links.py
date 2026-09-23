"""Validated, private link values for First Mate features.

This module parses and normalizes caller-supplied links. It never resolves a
host, opens a connection, fetches a page, previews a destination, or publishes
a URL. Storage and the authenticated API own durability; this module only
answers whether an absolute HTTP(S) URL is bounded and safe to retain, and how
to recognize an exact GitHub pull request.

General links preserve their path, query, and fragment. Recognized GitHub pull
request paths collapse to the pull request root so repeated references to the
same PR deduplicate. The classification says nothing about draft, ready,
merged, or closed state.
"""
from __future__ import annotations

import re
from typing import Any, Mapping
from urllib.parse import SplitResult, urlsplit, urlunsplit

MAX_URL_LENGTH = 4096
MAX_TITLE_LENGTH = 300
MAX_KIND_LENGTH = 32
LINK_KINDS = ("pull_request", "link")
INTERNAL_LINK_SOURCES = ("agent", "discovery")
PROVENANCE_FIELDS = (
    ("native_session_id", 500),
    ("assignment_id", 200),
    ("document_id", 200),
    ("message_id", 200),
    ("observed_at", 64),
)

_PR_PATH = re.compile(r"^/([^/]+)/([^/]+)/pull/(\d+)(?:/.*)?$")
_HOST_LABEL = r"(?!-)[A-Za-z0-9-]{1,63}(?<!-)"
_HOST = re.compile(rf"^{_HOST_LABEL}(?:\.{_HOST_LABEL})*$")


class LinkValidationError(ValueError):
    """A caller-supplied link value is not safe to persist."""


def _bounded_text(value: Any, name: str, maximum: int, *, optional: bool = False) -> str:
    if value is None and optional:
        return ""
    if not isinstance(value, str):
        raise LinkValidationError(f"{name} must be a string")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise LinkValidationError(f"{name} contains control characters")
    if not optional and not value.strip():
        raise LinkValidationError(f"{name} is required")
    if len(value) > maximum:
        raise LinkValidationError(f"{name} is too long")
    return value


def _parse_absolute_http_url(value: Any) -> SplitResult:
    text = _bounded_text(value, "url", MAX_URL_LENGTH).strip()
    if any(character.isspace() for character in text):
        raise LinkValidationError("URL contains whitespace")
    try:
        parsed = urlsplit(text)
    except ValueError as exc:
        raise LinkValidationError("URL is malformed") from exc
    if parsed.scheme.lower() not in {"http", "https"}:
        raise LinkValidationError("Use an absolute http or https URL")
    if parsed.username is not None or parsed.password is not None:
        raise LinkValidationError("URL credentials are not allowed")
    hostname = parsed.hostname or ""
    if not hostname or len(hostname) > 253 or not _HOST.fullmatch(hostname):
        raise LinkValidationError("URL host is malformed")
    try:
        port = parsed.port
    except ValueError as exc:
        raise LinkValidationError("URL port is malformed") from exc
    if port is not None and not 1 <= port <= 65535:
        raise LinkValidationError("URL port is malformed")
    expected_netloc = hostname if port is None else f"{hostname}:{port}"
    if parsed.netloc.lower() != expected_netloc.lower():
        raise LinkValidationError("URL host is malformed")
    return parsed


def parse_github_pull_request(value: Any) -> dict[str, Any] | None:
    """Return the exact GitHub PR identity for a URL, or None.

    Only an exact ``github.com`` host and ``/<owner>/<repo>/pull/<number>`` path
    qualify, matching the companion's existing GitHub URL convention.
    """
    try:
        parsed = _parse_absolute_http_url(value)
    except LinkValidationError:
        return None
    if (parsed.hostname or "").lower() != "github.com":
        return None
    match = _PR_PATH.match(parsed.path)
    if match is None:
        return None
    owner, repo, number = match.groups()
    return {
        "url": f"https://github.com/{owner}/{repo}/pull/{int(number)}",
        "host": "github.com",
        "owner": owner,
        "repo": repo,
        "number": int(number),
    }


def default_link_title(canonical_url: str, kind: str) -> str:
    """Derive an inspectable display title without claiming PR lifecycle."""
    if kind == "pull_request":
        match = _PR_PATH.match(urlsplit(canonical_url).path)
        if match is not None and (urlsplit(canonical_url).hostname or "").lower() == "github.com":
            owner, repo, number = match.groups()
            return f"{owner}/{repo} #{int(number)}"
    hostname = urlsplit(canonical_url).hostname or ""
    return hostname[:MAX_TITLE_LENGTH]


def normalize_link(value: Any, *, title: Any = None, kind: Any = None) -> dict[str, Any]:
    """Validate and canonicalize one link value.

    Returns ``url`` (canonical), ``kind`` (``pull_request`` or ``link``),
    ``title`` (caller title or a safe derived title), ``title_supplied``, and
    the recognized PR identity when applicable. Raises ``LinkValidationError``
    for unsupported schemes, credentials, malformed hosts or ports, control
    characters, and out-of-range values.
    """
    parsed = _parse_absolute_http_url(value)
    pull_request = None
    if (parsed.hostname or "").lower() == "github.com":
        pull_request = parse_github_pull_request(value)
    if kind is None:
        normalized_kind = "pull_request" if pull_request is not None else "link"
    else:
        normalized_kind = _bounded_text(kind, "kind", MAX_KIND_LENGTH).strip()
        if normalized_kind not in LINK_KINDS:
            raise LinkValidationError("kind must be pull_request or link")
    supplied_title = _bounded_text(title, "title", MAX_TITLE_LENGTH, optional=True).strip()
    if pull_request is not None:
        canonical_url = pull_request["url"]
    else:
        canonical_url = urlunsplit((
            parsed.scheme.lower(),
            parsed.hostname + (f":{parsed.port}" if parsed.port is not None else ""),
            parsed.path,
            parsed.query,
            parsed.fragment,
        ))
    normalized: dict[str, Any] = {
        "url": canonical_url,
        "kind": normalized_kind,
        "title": supplied_title or default_link_title(canonical_url, normalized_kind),
        "title_supplied": bool(supplied_title),
    }
    if pull_request is not None:
        normalized.update({"owner": pull_request["owner"], "repo": pull_request["repo"],
                           "number": pull_request["number"]})
    return normalized


def validate_internal_link_source(source: Any) -> str:
    """Trusted upserts may only claim agent or discovery provenance."""
    if not isinstance(source, str) or source not in INTERNAL_LINK_SOURCES:
        raise LinkValidationError("Unknown link source")
    return source


def validate_link_provenance(provenance: Any) -> dict[str, str]:
    """Accept a bounded provenance envelope from trusted runtime callers only."""
    if provenance is None:
        return {}
    if not isinstance(provenance, Mapping):
        raise LinkValidationError("provenance must be an object")
    allowed = {name for name, _ in PROVENANCE_FIELDS}
    if set(provenance) - allowed:
        raise LinkValidationError("provenance contains an unsupported field")
    result: dict[str, str] = {}
    for name, maximum in PROVENANCE_FIELDS:
        value = provenance.get(name)
        if value is None:
            continue
        result[name] = _bounded_text(value, "provenance " + name, maximum)
    return result

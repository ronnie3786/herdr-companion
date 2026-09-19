"""File bug reports and feature requests from the Herdr app as public GitHub issues.

The Mac app posts a verbatim note plus optional attachments. The companion server
stores a private copy under its state directory, uploads the attachments as assets
on a rolling ``issue-attachments`` release (the same pattern the repository uses
for the ``macos-updates`` feed), and creates the issue with the operator's
authenticated ``gh`` CLI. The issue body ends with a machine-readable HTML comment
marker that the Code Factory daemon reads back with :func:`parse_report_marker`.

Attachment bytes only live on disk while ``gh`` needs them: once the pipeline has
finished (filed or failed) they are removed again and only the small
``report.json`` and ``issue-body.md`` records remain. Assets that were already
published when issue creation failed are deleted from the release on a best-effort
basis; the ones that could not be removed are listed as ``orphanedAssets`` in
``report.json``.

``gh`` always runs with ``agent_environment(..., integration=False)``: provider
credentials are inherited, Herdr control tokens are never exported. Every ``gh``
step that reads a file runs inside the report directory and receives bare file
names, so the companion's filesystem layout never reaches ``gh`` or its error
text. Nothing in this module reads the network directly.
"""
from __future__ import annotations

import base64
import binascii
import json
import os
import re
import subprocess
import threading
import unicodedata
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Mapping, Optional

from . import agent_runs, attachments
from .agent_runs import AgentRunError
from .child_environment import agent_environment

MAX_TITLE_CHARS = 200
MAX_BODY_CHARS = 20_000
MAX_ATTACHMENTS = 6
MAX_ATTACHMENT_BYTES = attachments.MAX_ATTACHMENT_BYTES
MAX_TOTAL_ATTACHMENT_BYTES = 40 * 1024 * 1024
# Six attachments of up to 40 MiB in total expand to roughly 54 MiB as base64;
# the remainder covers the note, the environment table, and JSON framing.
MAX_ISSUE_REPORT_JSON_BYTES = 60 * 1024 * 1024
MAX_ENVIRONMENT_ENTRIES = 40
MAX_ENVIRONMENT_KEY_CHARS = 64
MAX_ENVIRONMENT_VALUE_CHARS = 512
MAX_CONTENT_TYPE_CHARS = 255
MAX_STDERR_CHARS = 300
# GitHub rejects issue bodies longer than this, and the rendered body repeats the
# environment (table plus marker), so the per-field limits alone do not bound it.
MAX_ISSUE_BODY_CHARS = 65_536
GH_TIMEOUT_SECONDS = 120
ATTACHMENTS_RELEASE_TAG = "issue-attachments"
ATTACHMENTS_RELEASE_TITLE = "Issue attachments"
ATTACHMENTS_RELEASE_NOTES = (
    "Files attached to issues filed from the Herdr app. "
    "This release is not an application download."
)
REPORT_LABEL = "herdr-app-report"
AUTOFIX_LABEL = "herdr-autofix"
KIND_LABELS = {"bug": "bug", "feature": "enhancement"}
# (color, description) for the labels this module owns; they are created with
# ``--force`` so their colour and description stay in sync with this file.
LABEL_DEFINITIONS = {
    REPORT_LABEL: ("8A7FD8", "Filed from the Herdr Mac app"),
    AUTOFIX_LABEL: ("AAA6F4", "Code Factory may implement and release this automatically"),
}
# GitHub's default kind labels. Repositories with a custom label scheme may have
# deleted them, so they are created when missing but never overwritten.
KIND_LABEL_DEFINITIONS = {
    "bug": ("d73a4a", "Something isn't working"),
    "enhancement": ("a2eeef", "New feature or request"),
}
# Keep this in sync with the Mac app's attachment picker (HerdrAttachmentTypes).
ALLOWED_EXTENSIONS = agent_runs.ATTACHMENT_EXTENSIONS
# Extensions GitHub renders inline from a release-asset URL; only these get an
# image preview line under "### Attachments".
IMAGE_EXTENSIONS = frozenset({"png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"})
MARKER_SCHEMA = 1
MARKER_NAME = "herdr-issue-report"
DEFAULT_CONTENT_TYPE = "application/octet-stream"
ISSUE_BODY_FILENAME = "issue-body.md"
RECORD_FILENAME = "report.json"
CLIENT_INDEX_DIRNAME = "clients"

_REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
# The server always writes the marker on one line, so the match never crosses a
# line break: an unclosed ``<!-- herdr-issue-report {`` typed into the note can
# neither swallow the genuine marker nor stand in for it.
_MARKER_RE = re.compile(r"<!--[ \t]*" + re.escape(MARKER_NAME) + r"[ \t]+(\{[^\r\n]*?\})[ \t]*-->")
_ISSUE_NUMBER_RE = re.compile(r"(\d+)\s*$")
_REPORT_ID_RE = re.compile(r"^isr_[0-9a-f]{12}$")
_CLIENT_REPORT_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
_PAYLOAD_KEYS = frozenset({"kind", "title", "body", "autofix", "environment", "attachments", "clientReportId"})
_ATTACHMENT_KEYS = frozenset({"filename", "contentType", "dataBase64"})
_UNAVAILABLE_REASON = (
    "Configure code_factory.repository or integrations.github_repository "
    "(owner/repo) to file issues from the app"
)
_MALFORMED_REASON = "The configured GitHub repository must use the form owner/repo"
_REDACTED_ROOT = "<issue-reports>"

Runner = Callable[..., Any]


class IssueReportError(ValueError):
    """A rejected report (HTTP 4xx) or a failed GitHub step (HTTP 502/503).

    ``report_id`` is set once a report has been stored, so a failure that happened
    after storage (and possibly after assets were published) can be traced back
    to its ``report.json``.
    """

    def __init__(
        self,
        message: str,
        *,
        code: str = "invalid_issue_report",
        status: int = 400,
        report_id: Optional[str] = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.status = status
        self.report_id = report_id


@dataclass(frozen=True)
class _Attachment:
    """One validated upload: the user's filename plus the release-asset name."""

    filename: str
    asset: str
    content_type: str
    data: bytes

    @property
    def is_image(self) -> bool:
        return _extension(self.asset) in IMAGE_EXTENSIONS


@dataclass(frozen=True)
class _Report:
    kind: str
    title: str
    body: str
    autofix: bool
    environment: dict[str, str]
    attachments: tuple[_Attachment, ...]
    client_report_id: Optional[str] = None


def _utc_timestamp(moment: datetime) -> str:
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _extension(name: str) -> str:
    return name.rsplit(".", 1)[-1].lower() if "." in name else ""


def _has_control_characters(value: str) -> bool:
    return any(ord(character) < 32 or ord(character) == 127 for character in value)


def _invalid(message: str) -> IssueReportError:
    return IssueReportError(message)


def _default_root(environ: Mapping[str, str]) -> Path:
    state_dir = environ.get("HERDR_STATE_DIR")
    if state_dir:
        return Path(state_dir).expanduser() / "issue-reports"
    home = Path(environ.get("HOME") or Path.home()).expanduser()
    return home / ".local" / "share" / "herdr-companion" / "issue-reports"


def _configured_repository(environ: Mapping[str, str]) -> tuple[Optional[str], Optional[str]]:
    """Return ``(repository, reason)``; exactly one of the two is ``None``."""
    raw = (environ.get("HERDR_CODE_FACTORY_REPOSITORY") or environ.get("HERDR_REVIEW_REPOSITORY") or "").strip()
    if not raw:
        return None, _UNAVAILABLE_REASON
    if not _REPOSITORY_RE.fullmatch(raw):
        return None, _MALFORMED_REASON
    return raw, None


def _trim_stderr(value: Any) -> str:
    text = " ".join(str(value or "").split())
    if len(text) > MAX_STDERR_CHARS:
        text = text[: MAX_STDERR_CHARS - 1].rstrip() + "…"
    return text


def _stderr_text(completed: Any) -> str:
    return str(getattr(completed, "stderr", "") or "")


def _release_is_missing(stderr: str) -> bool:
    """Whether ``gh release view`` failed because the tag does not exist.

    Every other failure (rate limit, expired token, network) is surfaced as-is
    instead of being followed by a ``release create`` that cannot succeed.
    """
    lowered = stderr.lower()
    return "not found" in lowered or "404" in lowered


def _escape_link_text(value: str) -> str:
    return value.replace("\\", "\\\\").replace("[", "\\[").replace("]", "\\]")


def _escape_table_cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\r", " ").replace("\n", " ")


def _asset_stem(filename: str) -> str:
    """An ASCII, URL-safe stem so the predicted release-asset URL is exact.

    GitHub rewrites asset names it does not like (spaces, accents), which would
    break the links written into the issue body, so the name is normalized here.
    The result never contains ``#``, which ``gh release upload`` would otherwise
    read as the start of a display label.
    """
    stem = filename.rsplit(".", 1)[0] if "." in filename else filename
    ascii_stem = "".join(
        character for character in unicodedata.normalize("NFKD", stem) if not unicodedata.combining(character)
    )
    safe = re.sub(r"[^A-Za-z0-9_-]+", "_", ascii_stem)
    return safe.strip("_")[:100] or "attachment"


# ---------------------------------------------------------------------------
# Validation


def _validate_kind(value: Any) -> str:
    if not isinstance(value, str) or value not in KIND_LABELS:
        raise _invalid("kind must be \"bug\" or \"feature\"")
    return value


def _validate_title(value: Any) -> str:
    if not isinstance(value, str):
        raise _invalid("title must be a string")
    # The Mac composer folds line breaks but lets a pasted tab through; a tab
    # is still "one line", so it becomes a space instead of a 400 after upload.
    title = value.replace("\t", " ").strip()
    if not title:
        raise _invalid("title is required")
    if len(title) > MAX_TITLE_CHARS:
        raise _invalid(f"title must be at most {MAX_TITLE_CHARS} characters")
    if _has_control_characters(title):
        raise _invalid("title must be a single line without control characters")
    return title


def _validate_body(value: Any) -> str:
    if not isinstance(value, str):
        raise _invalid("body must be a string")
    body = value.rstrip("\r\n")
    if not body.strip():
        raise _invalid("body is required")
    if len(body) > MAX_BODY_CHARS:
        raise _invalid(f"body must be at most {MAX_BODY_CHARS} characters")
    # The note is posted verbatim, so pasted logs may carry escape sequences and
    # other C0 controls; only NUL, which neither JSON transport nor GitHub keeps
    # intact, is refused.
    if "\x00" in body:
        raise _invalid("body must not contain the NUL control character")
    return body


def _validate_autofix(value: Any) -> bool:
    if value is None:
        return True
    if not isinstance(value, bool):
        raise _invalid("autofix must be true or false")
    return value


def _validate_environment(value: Any) -> dict[str, str]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise _invalid("environment must be an object of string values")
    if len(value) > MAX_ENVIRONMENT_ENTRIES:
        raise _invalid(f"environment must have at most {MAX_ENVIRONMENT_ENTRIES} entries")
    result: dict[str, str] = {}
    for key, entry in value.items():
        if (
            not isinstance(key, str)
            or not key.strip()
            or len(key) > MAX_ENVIRONMENT_KEY_CHARS
            or _has_control_characters(key)
        ):
            raise _invalid("environment keys must be short strings without control characters")
        if not isinstance(entry, str) or len(entry) > MAX_ENVIRONMENT_VALUE_CHARS or _has_control_characters(entry):
            raise _invalid(f"environment.{key.strip()} must be a string of at most {MAX_ENVIRONMENT_VALUE_CHARS} characters")
        result[key] = entry
    return result


def _validate_client_report_id(value: Any) -> Optional[str]:
    if value is None:
        return None
    if not isinstance(value, str) or not _CLIENT_REPORT_ID_RE.fullmatch(value):
        raise _invalid("clientReportId must be 8 to 64 letters, digits, '-' or '_'")
    return value


def _validate_filename(value: Any) -> str:
    try:
        return agent_runs._sanitize_attachment_filename(value)
    except AgentRunError as exc:
        raise IssueReportError(str(exc)) from None


def _validate_content_type(value: Any) -> str:
    if value is None:
        return DEFAULT_CONTENT_TYPE
    if not isinstance(value, str) or len(value) > MAX_CONTENT_TYPE_CHARS or _has_control_characters(value):
        raise _invalid("attachment contentType must be a short printable string")
    return value.strip() or DEFAULT_CONTENT_TYPE


def _decode_attachment(value: Any) -> bytes:
    if not isinstance(value, str) or not value:
        raise _invalid("attachment dataBase64 is required")
    if len(value) > ((MAX_ATTACHMENT_BYTES + 2) // 3) * 4:
        raise IssueReportError(
            f"attachment exceeds {MAX_ATTACHMENT_BYTES // (1024 * 1024)} MB limit",
            code="issue_attachment_too_large",
            status=413,
        )
    try:
        data = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        raise _invalid("attachment dataBase64 must be valid base64") from None
    if not data:
        raise _invalid("attachment file is empty")
    if len(data) > MAX_ATTACHMENT_BYTES:
        raise IssueReportError(
            f"attachment exceeds {MAX_ATTACHMENT_BYTES // (1024 * 1024)} MB limit",
            code="issue_attachment_too_large",
            status=413,
        )
    return data


def _validate_attachments(value: Any, report_id: str) -> tuple[_Attachment, ...]:
    if value is None:
        return ()
    if not isinstance(value, list) or len(value) > MAX_ATTACHMENTS:
        raise _invalid(f"attachments must be a list of at most {MAX_ATTACHMENTS} items")
    used: set[str] = set()
    total = 0
    result: list[_Attachment] = []
    for item in value:
        if not isinstance(item, dict) or not set(item) <= _ATTACHMENT_KEYS or "filename" not in item or "dataBase64" not in item:
            raise _invalid("attachment must have filename, contentType, and dataBase64")
        filename = _validate_filename(item.get("filename"))
        content_type = _validate_content_type(item.get("contentType"))
        data = _decode_attachment(item.get("dataBase64"))
        total += len(data)
        if total > MAX_TOTAL_ATTACHMENT_BYTES:
            raise IssueReportError(
                f"attachments exceed {MAX_TOTAL_ATTACHMENT_BYTES // (1024 * 1024)} MB in total",
                code="issue_attachment_too_large",
                status=413,
            )
        stem = _asset_stem(filename)
        extension = _extension(filename)
        asset = f"{report_id}-{stem}.{extension}"
        counter = 1
        while asset.casefold() in used:
            asset = f"{report_id}-{stem}-{counter}.{extension}"
            counter += 1
        used.add(asset.casefold())
        result.append(_Attachment(filename=filename, asset=asset, content_type=content_type, data=data))
    return tuple(result)


def _validate_payload(payload: Any, report_id: str) -> _Report:
    if not isinstance(payload, dict):
        raise _invalid("report must be a JSON object")
    unknown = set(payload) - _PAYLOAD_KEYS
    if unknown:
        raise _invalid("report contains unsupported fields: " + ", ".join(sorted(str(key) for key in unknown)))
    return _Report(
        kind=_validate_kind(payload.get("kind")),
        title=_validate_title(payload.get("title")),
        body=_validate_body(payload.get("body")),
        autofix=_validate_autofix(payload.get("autofix")),
        environment=_validate_environment(payload.get("environment")),
        attachments=_validate_attachments(payload.get("attachments"), report_id),
        client_report_id=_validate_client_report_id(payload.get("clientReportId")),
    )


# ---------------------------------------------------------------------------
# Issue body


def asset_url(repository: str, asset: str) -> str:
    """The stable download URL of a release asset on the attachments release."""
    return f"https://github.com/{repository}/releases/download/{ATTACHMENTS_RELEASE_TAG}/{asset}"


def render_issue_body(
    *,
    body: str,
    attachments: list[dict[str, Any]],
    environment: Mapping[str, str],
    marker: Mapping[str, Any],
) -> str:
    """Compose the GitHub issue body: verbatim note, attachments, environment, marker.

    ``attachments`` items carry ``name``, ``url`` and ``asset``. The marker JSON is
    emitted on one line with sorted keys; ``--`` never appears inside it so the
    HTML comment stays well formed.
    """
    sections = [body]
    if attachments:
        lines = ["### Attachments"]
        for item in attachments:
            label = _escape_link_text(str(item["name"]))
            lines.append(f"- [{label}]({item['url']})")
            if _extension(str(item["asset"])) in IMAGE_EXTENSIONS:
                lines.append(f"![{label}]({item['url']})")
        sections.append("\n".join(lines))
    if environment:
        rows = ["<details>", "<summary>Environment</summary>", "", "| Key | Value |", "| --- | --- |"]
        for key in sorted(environment):
            rows.append(f"| {_escape_table_cell(key)} | {_escape_table_cell(environment[key])} |")
        rows.append("</details>")
        sections.append("\n".join(rows))
    encoded = json.dumps(marker, sort_keys=True, separators=(",", ":")).replace("--", "-\\u002d")
    sections.append(f"<!-- {MARKER_NAME} {encoded} -->")
    return "\n\n".join(sections) + "\n"


def parse_report_marker(issue_body: Any) -> Optional[dict[str, Any]]:
    """Return the ``herdr-issue-report`` marker embedded in an issue body, if any.

    The last well-formed marker wins because the server appends its own marker,
    on a line of its own, after the verbatim note. Markers are matched one line
    at a time, so neither a complete forged marker nor an unclosed opener typed
    into the note can impersonate or hide the genuine one.
    """
    if not isinstance(issue_body, str) or not issue_body:
        return None
    for raw in reversed(_MARKER_RE.findall(issue_body)):
        try:
            data = json.loads(raw)
        except ValueError:
            continue
        if isinstance(data, dict) and data.get("schema") == MARKER_SCHEMA and isinstance(data.get("reportId"), str):
            return data
    return None


# ---------------------------------------------------------------------------
# Reporter


class IssueReporter:
    """Validate, store, and file one issue report at a time through ``gh``.

    ``runner`` mirrors ``subprocess.run`` and is injected by tests. ``root`` is the
    private storage directory (created lazily with mode 0o700). ``clock`` returns
    an aware UTC ``datetime``.

    A payload may carry an optional ``clientReportId`` chosen by the client. When
    a report with that key was already filed, ``submit`` returns the stored
    result instead of creating a second issue, so a retry after a timed-out
    response never duplicates the report or its public assets.
    """

    def __init__(
        self,
        environ: Mapping[str, str],
        *,
        runner: Optional[Runner] = None,
        root: Optional[str | Path] = None,
        clock: Optional[Callable[[], datetime]] = None,
    ) -> None:
        self.environ: dict[str, str] = dict(environ)
        self._runner: Runner = runner or subprocess.run
        self._clock: Callable[[], datetime] = clock or (lambda: datetime.now(timezone.utc))
        self.root: Path = Path(root).expanduser() if root is not None else _default_root(self.environ)
        self.repository, self._unavailable_reason = _configured_repository(self.environ)
        self._lock = threading.Lock()
        # Label creation succeeds at most once per reporter (one per process).
        self._labels_ready: set[str] = set()

    # -- public API ----------------------------------------------------------

    def capabilities(self) -> dict[str, Any]:
        """Describe the reporter without shelling out."""
        return {
            "ok": True,
            "available": self.repository is not None,
            "repository": self.repository,
            "reason": self._unavailable_reason,
            "maxAttachments": MAX_ATTACHMENTS,
            "maxAttachmentBytes": MAX_ATTACHMENT_BYTES,
            "maxTotalAttachmentBytes": MAX_TOTAL_ATTACHMENT_BYTES,
            "attachmentHosting": "release-assets",
            "publicRepository": True,
            "clientReportIdSupported": True,
            "labels": {
                "report": REPORT_LABEL,
                "autofix": AUTOFIX_LABEL,
                "kinds": dict(KIND_LABELS),
            },
        }

    def submit(self, payload: Any) -> dict[str, Any]:
        """Validate ``payload``, persist it, and create the GitHub issue."""
        if self.repository is None:
            raise IssueReportError(
                self._unavailable_reason or _UNAVAILABLE_REASON,
                code="issue_reports_unavailable",
                status=503,
            )
        report_id = "isr_" + uuid.uuid4().hex[:12]
        report = _validate_payload(payload, report_id)
        with self._lock:
            if report.client_report_id is not None:
                replayed = self._replay(report.client_report_id)
                if replayed is not None:
                    return replayed
            return self._file(report_id, report)

    # -- pipeline ------------------------------------------------------------

    def _file(self, report_id: str, report: _Report) -> dict[str, Any]:
        repository = self.repository
        assert repository is not None
        created_at = _utc_timestamp(self._clock())
        stored: list[dict[str, Any]] = [
            {
                "filename": attachment.filename,
                "asset": attachment.asset,
                "url": asset_url(repository, attachment.asset),
                "contentType": attachment.content_type,
                "size": len(attachment.data),
            }
            for attachment in report.attachments
        ]
        marker = {
            "schema": MARKER_SCHEMA,
            "reportId": report_id,
            "kind": report.kind,
            "autofix": report.autofix,
            "attachments": [
                {
                    "name": item["filename"],
                    "asset": item["asset"],
                    "url": item["url"],
                    "contentType": item["contentType"],
                    "size": item["size"],
                }
                for item in stored
            ],
            "environment": dict(report.environment),
        }
        issue_body = render_issue_body(
            body=report.body,
            attachments=[{"name": item["filename"], "url": item["url"], "asset": item["asset"]} for item in stored],
            environment=report.environment,
            marker=marker,
        )
        # Rejected before anything is stored or published: GitHub would refuse the
        # issue after the attachments had already gone public.
        if len(issue_body) > MAX_ISSUE_BODY_CHARS:
            raise IssueReportError(
                f"report is too long for a GitHub issue (at most {MAX_ISSUE_BODY_CHARS} characters once rendered)",
                code="issue_report_too_long",
                status=413,
            )
        directory = self._prepare_directory(report_id)
        for attachment in report.attachments:
            self._write_private(directory / attachment.asset, attachment.data)
        record: dict[str, Any] = {
            "id": report_id,
            "clientReportId": report.client_report_id,
            "createdAt": created_at,
            "repository": repository,
            "kind": report.kind,
            "title": report.title,
            "body": report.body,
            "autofix": report.autofix,
            "environment": dict(report.environment),
            "attachments": stored,
            "status": "pending",
            "issueNumber": None,
            "issueUrl": None,
        }
        self._write_record(directory, record)
        if report.client_report_id is not None:
            self._write_client_index(report.client_report_id, report_id)
        self._write_private(directory / ISSUE_BODY_FILENAME, issue_body.encode("utf-8"))
        labels = [REPORT_LABEL, KIND_LABELS[report.kind]]
        if report.autofix:
            labels.append(AUTOFIX_LABEL)
        uploaded = False
        try:
            try:
                self._ensure_labels(labels)
                if stored:
                    self._ensure_release()
                    self._gh("release", "upload", ATTACHMENTS_RELEASE_TAG, "--repo", repository, "--clobber",
                            *[item["asset"] for item in stored], cwd=directory)
                    uploaded = True
                number, url = self._create_issue(report.title, labels, cwd=directory)
            except IssueReportError as exc:
                exc.report_id = report_id
                record.update({"status": "failed", "error": {"code": exc.code, "message": str(exc)}})
                if uploaded:
                    record["orphanedAssets"] = self._remove_uploaded_assets(stored)
                self._write_record(directory, record)
                raise
            except Exception:
                if uploaded:
                    self._remove_uploaded_assets(stored)
                raise
        finally:
            # The bytes are on GitHub (or the report failed); either way the
            # private copy is not kept, so storage does not grow with every report.
            self._discard_attachment_files(directory, stored)
        record.update({"status": "filed", "issueNumber": number, "issueUrl": url})
        self._write_record(directory, record)
        return self._result(record)

    def _replay(self, client_report_id: str) -> Optional[dict[str, Any]]:
        """The stored result for ``client_report_id``, or ``None`` to file anew.

        A record that never reached ``filed`` is checked against GitHub first: the
        issue may exist when ``gh issue create`` was interrupted after the request
        went through. The marker's ``reportId`` confirms the match.
        """
        try:
            previous_id = (self.root / CLIENT_INDEX_DIRNAME / client_report_id).read_text(encoding="utf-8").strip()
        except OSError:
            return None
        if not _REPORT_ID_RE.fullmatch(previous_id):
            return None
        directory = self.root / previous_id
        try:
            record = json.loads((directory / RECORD_FILENAME).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        if not isinstance(record, dict) or record.get("id") != previous_id:
            return None
        if record.get("status") != "filed":
            found = self._find_filed_issue(previous_id)
            if found is None:
                return None
            number, url = found
            record.pop("error", None)
            record.update({"status": "filed", "issueNumber": number, "issueUrl": url})
            self._write_record(directory, record)
        try:
            return self._result(record)
        except (KeyError, TypeError):
            return None

    @staticmethod
    def _result(record: Mapping[str, Any]) -> dict[str, Any]:
        return {
            "ok": True,
            "report": {
                "id": record["id"],
                "kind": record["kind"],
                "title": record["title"],
                "autofix": record["autofix"],
                "issueNumber": record["issueNumber"],
                "issueUrl": record["issueUrl"],
                "repository": record["repository"],
                "attachments": [
                    {
                        "filename": item["filename"],
                        "url": item["url"],
                        "contentType": item["contentType"],
                        "size": item["size"],
                    }
                    for item in record["attachments"]
                ],
                "createdAt": record["createdAt"],
            },
        }

    # -- GitHub steps --------------------------------------------------------

    def _ensure_labels(self, names: list[str]) -> None:
        for name in names:
            if name in self._labels_ready:
                continue
            if name in LABEL_DEFINITIONS:
                color, description = LABEL_DEFINITIONS[name]
                self._gh("label", "create", name, "--repo", self.repository, "--color", color,
                         "--description", description, "--force")
            else:
                # A kind label may already exist with the operator's own colour
                # and description: no --force, and "already exists" is success.
                color, description = KIND_LABEL_DEFINITIONS[name]
                completed = self._run_gh(
                    ["label", "create", name, "--repo", self.repository, "--color", color, "--description", description],
                    check=False,
                )
                if completed.returncode != 0 and "already exists" not in _stderr_text(completed).lower():
                    raise self._gh_failure("gh label create", completed)
            self._labels_ready.add(name)

    def _ensure_release(self) -> None:
        existing = self._run_gh(
            ["release", "view", ATTACHMENTS_RELEASE_TAG, "--repo", self.repository, "--json", "tagName"],
            check=False,
        )
        if existing.returncode == 0:
            return
        if not _release_is_missing(_stderr_text(existing)):
            raise self._gh_failure("gh release view", existing)
        self._gh("release", "create", ATTACHMENTS_RELEASE_TAG, "--repo", self.repository, "--target", "main",
                 "--prerelease", "--latest=false", "--title", ATTACHMENTS_RELEASE_TITLE,
                 "--notes", ATTACHMENTS_RELEASE_NOTES)

    def _remove_uploaded_assets(self, stored: list[dict[str, Any]]) -> list[str]:
        """Best-effort deletion of published assets; returns the names left behind."""
        orphaned: list[str] = []
        for item in stored:
            asset = str(item["asset"])
            try:
                completed = self._run_gh(
                    ["release", "delete-asset", ATTACHMENTS_RELEASE_TAG, asset, "--repo", self.repository, "--yes"],
                    check=False,
                )
            except IssueReportError:
                orphaned.append(asset)
                continue
            if completed.returncode != 0:
                orphaned.append(asset)
        return orphaned

    def _create_issue(self, title: str, labels: list[str], *, cwd: Path) -> tuple[int, str]:
        arguments = ["issue", "create", "--repo", self.repository, "--title", title, "--body-file", ISSUE_BODY_FILENAME]
        for label in labels:
            arguments += ["--label", label]
        stdout = self._gh(*arguments, cwd=cwd)
        lines = [line.strip() for line in str(stdout).splitlines() if line.strip()]
        last = lines[-1] if lines else ""
        match = _ISSUE_NUMBER_RE.search(last)
        if not match:
            raise IssueReportError("gh issue create did not return an issue number", code="github_failed", status=502)
        number = int(match.group(1))
        url = last if last.startswith("https://") else f"https://github.com/{self.repository}/issues/{number}"
        return number, url

    def _find_filed_issue(self, report_id: str) -> Optional[tuple[int, str]]:
        """Look up an issue whose marker carries ``report_id``; ``None`` when absent."""
        completed = self._run_gh(
            ["issue", "list", "--repo", self.repository, "--label", REPORT_LABEL, "--state", "all",
             "--search", f"{report_id} in:body", "--limit", "10", "--json", "number,url,body"],
            check=False,
        )
        if completed.returncode != 0:
            return None
        try:
            items = json.loads(str(getattr(completed, "stdout", "") or "") or "[]")
        except ValueError:
            return None
        for item in items if isinstance(items, list) else []:
            if not isinstance(item, dict):
                continue
            marker = parse_report_marker(item.get("body"))
            number = item.get("number")
            if marker is not None and marker.get("reportId") == report_id and isinstance(number, int):
                url = item.get("url")
                if not isinstance(url, str) or not url.startswith("https://"):
                    url = f"https://github.com/{self.repository}/issues/{number}"
                return number, url
        return None

    def _gh(self, *arguments: str, cwd: Optional[Path] = None) -> str:
        return str(self._run_gh(list(arguments), check=True, cwd=cwd).stdout or "")

    def _run_gh(self, arguments: list[str], *, check: bool, cwd: Optional[Path] = None) -> Any:
        """Run one ``gh`` command; failures never echo the environment or local paths."""
        label = "gh " + " ".join(arguments[:2])
        try:
            completed = self._runner(
                ["gh", *arguments],
                capture_output=True,
                text=True,
                timeout=GH_TIMEOUT_SECONDS,
                env=agent_environment(self.environ, integration=False),
                cwd=str(cwd) if cwd is not None else None,
            )
        except FileNotFoundError:
            raise IssueReportError("The gh CLI is not installed on the companion", code="github_failed", status=502) from None
        except subprocess.TimeoutExpired:
            raise IssueReportError(f"{label} timed out after {GH_TIMEOUT_SECONDS}s", code="github_failed", status=502) from None
        except OSError as exc:
            raise IssueReportError(f"{label} could not start: {exc.strerror or 'OS error'}", code="github_failed", status=502) from None
        if check and completed.returncode != 0:
            raise self._gh_failure(label, completed)
        return completed

    def _gh_failure(self, label: str, completed: Any) -> IssueReportError:
        detail = _trim_stderr(self._redact(_stderr_text(completed)))
        message = f"{label} failed" + (f": {detail}" if detail else f" (exit {completed.returncode})")
        return IssueReportError(message, code="github_failed", status=502)

    def _redact(self, text: str) -> str:
        return text.replace(str(self.root), _REDACTED_ROOT)

    # -- storage -------------------------------------------------------------

    def _prepare_directory(self, report_id: str) -> Path:
        try:
            self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
            directory = self.root / report_id
            directory.mkdir(mode=0o700)
        except OSError as exc:
            raise IssueReportError("Could not store the report", code="issue_report_storage_failed", status=503) from exc
        return directory

    @staticmethod
    def _write_private(path: Path, data: bytes) -> None:
        try:
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(data)
        except OSError as exc:
            raise IssueReportError("Could not store the report", code="issue_report_storage_failed", status=503) from exc

    def _write_record(self, directory: Path, record: Mapping[str, Any]) -> None:
        encoded = json.dumps(record, indent=2, sort_keys=True, ensure_ascii=False).encode("utf-8")
        self._write_private(directory / RECORD_FILENAME, encoded)

    def _write_client_index(self, client_report_id: str, report_id: str) -> None:
        index = self.root / CLIENT_INDEX_DIRNAME
        try:
            index.mkdir(mode=0o700, exist_ok=True)
        except OSError as exc:
            raise IssueReportError("Could not store the report", code="issue_report_storage_failed", status=503) from exc
        self._write_private(index / client_report_id, report_id.encode("ascii"))

    @staticmethod
    def _discard_attachment_files(directory: Path, stored: list[dict[str, Any]]) -> None:
        for item in stored:
            try:
                (directory / str(item["asset"])).unlink()
            except OSError:
                continue

"""HTTP client for a SimPortal server (protocol 1).

SimPortal saves compiled iOS simulator builds and streams on-demand simulator
previews. This client is the companion's only path to it: the service token is
read from private configuration, sent in a header, and never placed in a URL,
log, error, or response. Redirects and ambient proxies are refused so the
credential cannot follow a changed origin.

The wire format is SimPortal's camelCase JSON. Durable mutations are accepted
with 202 and identified by the caller's ``requestId``; replaying the identical
body is safe and returns the retained operation. See
docs/first-mate/simulator-previews.md for the contract Herdr relies on.
"""
from __future__ import annotations

import contextlib
import ipaddress
import json
import re
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Mapping

from .secret_file import SecretFileError, load_private_bearer_token_file, validate_bearer_token

PROTOCOL_VERSION = 1
UUID_RE = re.compile(r"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$", re.IGNORECASE)
SCOPE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
TERMINAL_OPERATION_STATUSES = frozenset({"succeeded", "failed", "cancelled", "interrupted", "outcome_unknown"})
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_ERROR_BYTES = 64 * 1024
_ERROR_CODE_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")


class SimPortalError(Exception):
    """A SimPortal request failed.

    ``transport`` failures (unreachable, timeout) and ``retryable`` statuses
    leave a durable request eligible for exact replay; everything else needs
    the caller to reconcile. Messages never contain the credential.
    """

    def __init__(self, message: str, *, code: str = "simportal_error", status: int | None = None,
                 retryable: bool = False, transport: bool = False) -> None:
        super().__init__(message)
        self.code = code
        self.status = status
        self.retryable = retryable or transport
        self.transport = transport


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request: Any, file_pointer: Any, code: int, message: str,
                         headers: Any, new_url: str) -> None:
        raise urllib.error.HTTPError(request.full_url, code, "SimPortal redirects are not allowed",
                                     headers, file_pointer)


def is_loopback_host(hostname: str | None) -> bool:
    if not hostname:
        return False
    if hostname.casefold() == "localhost":
        return True
    try:
        return ipaddress.ip_address(hostname.strip("[]")).is_loopback
    except ValueError:
        return False


def validate_origin(value: Any) -> str:
    """An http(s) origin: HTTPS anywhere, plain HTTP only on loopback."""

    if not isinstance(value, str) or not value.strip():
        raise SimPortalError("SimPortal URL is not configured", code="simulator_unconfigured")
    try:
        parsed = urllib.parse.urlsplit(value.strip())
        hostname = parsed.hostname
        parsed.port
    except ValueError:
        raise SimPortalError("SimPortal URL is invalid", code="simulator_misconfigured") from None
    if (parsed.scheme not in {"http", "https"} or not hostname or parsed.username or parsed.password
            or parsed.path not in {"", "/"} or parsed.query or parsed.fragment
            or (parsed.scheme == "http" and not is_loopback_host(hostname))):
        raise SimPortalError("Use HTTPS for a remote SimPortal, or HTTP on loopback, without credentials or a path",
                             code="simulator_misconfigured")
    return value.strip().rstrip("/")


def is_uuid(value: Any) -> bool:
    return isinstance(value, str) and bool(UUID_RE.fullmatch(value))


def is_scope_id(value: Any) -> bool:
    return isinstance(value, str) and bool(SCOPE_ID_RE.fullmatch(value))


def load_token(environ: Mapping[str, str]) -> str:
    """The service token from HERDR_SIMPORTAL_TOKEN or a private token file."""

    try:
        if environ.get("HERDR_SIMPORTAL_TOKEN"):
            return validate_bearer_token(environ["HERDR_SIMPORTAL_TOKEN"], field="SimPortal token", required=True)
        if environ.get("HERDR_SIMPORTAL_TOKEN_FILE"):
            return load_private_bearer_token_file(environ["HERDR_SIMPORTAL_TOKEN_FILE"], field="SimPortal token file")
    except (SecretFileError, OSError, ValueError):
        # Secret errors can name the private path; keep them out of API text.
        raise SimPortalError("The SimPortal token is unreadable or not private", code="simulator_misconfigured") from None
    raise SimPortalError("The SimPortal token is not configured", code="simulator_unconfigured")


def _safe_text(value: Any, fallback: str, maximum: int = 300) -> str:
    if not isinstance(value, str):
        return fallback
    cleaned = " ".join(value.replace("\x00", "").split())
    return cleaned[:maximum] or fallback


class SimPortalClient:
    """Small no-redirect JSON transport for one SimPortal origin."""

    def __init__(self, origin: str, token: str, *, timeout: float = 10,
                 opener: Callable[..., Any] | Any | None = None) -> None:
        self.origin = validate_origin(origin)
        try:
            self._token = validate_bearer_token(token, field="SimPortal token", required=True)
        except SecretFileError:
            raise SimPortalError("The SimPortal token is unusable", code="simulator_misconfigured") from None
        self.timeout = timeout
        if opener is None:
            self._open = urllib.request.build_opener(urllib.request.ProxyHandler({}), _RejectRedirects()).open
        elif callable(opener):
            self._open = opener
        else:
            self._open = opener.open

    @property
    def token(self) -> str:
        return self._token

    def _redact(self, text: str) -> str:
        return text.replace(self._token, "[redacted]") if self._token else text

    def request(self, method: str, path: str, body: Any = None, *, query: Mapping[str, Any] | None = None,
                timeout: float | None = None) -> dict[str, Any]:
        if not path.startswith("/api/") or "?" in path or "#" in path:
            raise SimPortalError("Internal SimPortal path is invalid", code="invalid_request")
        url = self.origin + path
        if query:
            url += "?" + urllib.parse.urlencode([(k, str(v)) for k, v in query.items() if v is not None])
        data: bytes | None = None
        headers = {"Accept": "application/json", "Authorization": "Bearer " + self._token,
                   "User-Agent": "herdr-companion-simportal/1"}
        if body is not None:
            data = json.dumps(body, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with self._open(request, timeout=timeout or self.timeout) as response:
                final_url = response.geturl() if callable(getattr(response, "geturl", None)) else url
                if final_url != url:
                    raise SimPortalError("SimPortal redirects are not allowed", code="simulator_misconfigured")
                raw = response.read(MAX_RESPONSE_BYTES + 1)
        except SimPortalError:
            raise
        except urllib.error.HTTPError as exc:
            with contextlib.closing(exc):
                raw = exc.read(MAX_ERROR_BYTES)
            raise self._http_error(exc.code, raw) from None
        except (urllib.error.URLError, OSError, TimeoutError):
            raise SimPortalError("SimPortal is not reachable", code="simulator_unavailable", transport=True) from None
        if len(raw) > MAX_RESPONSE_BYTES:
            raise SimPortalError("SimPortal response is too large", code="simulator_invalid_response")
        try:
            result = json.loads(raw)
        except (ValueError, UnicodeError):
            raise SimPortalError("SimPortal returned invalid JSON", code="simulator_invalid_response") from None
        if not isinstance(result, dict):
            raise SimPortalError("SimPortal returned an invalid response", code="simulator_invalid_response")
        return result

    def _http_error(self, status: int, raw: bytes) -> SimPortalError:
        code, message = f"http_{status}", f"SimPortal returned HTTP {status}"
        try:
            decoded = json.loads(raw)
            if isinstance(decoded, dict):
                candidate = str(decoded.get("code") or "")
                if _ERROR_CODE_RE.fullmatch(candidate):
                    code = candidate
                message = _safe_text(self._redact(str(decoded.get("error") or "")), message)
        except (ValueError, UnicodeError):
            pass
        if status in {401, 403}:
            return SimPortalError("SimPortal rejected the companion's credential", code="simulator_auth", status=status)
        if status == 421:
            return SimPortalError("SimPortal refused this host name; use its loopback or tailnet URL",
                                  code="simulator_misconfigured", status=status)
        retryable = status == 429 or (status >= 500 and code != "ledger_unavailable")
        return SimPortalError(message, code=code, status=status, retryable=retryable)

    # Discovery -----------------------------------------------------------------

    def health(self) -> dict[str, Any]:
        return self.request("GET", "/api/health", timeout=4)

    def capabilities(self) -> dict[str, Any]:
        return self.request("GET", "/api/capabilities", timeout=15)

    def storage(self) -> dict[str, Any]:
        return self.request("GET", "/api/storage", timeout=30)

    # Builds ----------------------------------------------------------------------

    def register_build(self, body: Mapping[str, Any]) -> dict[str, Any]:
        return self.request("POST", "/api/builds", dict(body))

    def build(self, build_id: str) -> dict[str, Any]:
        return self.request("GET", "/api/builds/" + _path_id(build_id))

    def builds(self, *, project_id: str, feature_id: str, after: str | None = None, limit: int = 100) -> dict[str, Any]:
        return self.request("GET", "/api/builds", query={"projectId": project_id, "featureId": feature_id,
                                                          "limit": limit, "after": after})

    # Portals and operations -----------------------------------------------------

    def start_portal(self, body: Mapping[str, Any]) -> dict[str, Any]:
        return self.request("POST", "/api/portals", dict(body))

    def portal(self, portal_id: str) -> dict[str, Any]:
        return self.request("GET", "/api/portals/" + _path_id(portal_id))

    def portals(self, *, build_id: str, after: str | None = None, limit: int = 100) -> dict[str, Any]:
        return self.request("GET", "/api/portals", query={"buildId": build_id, "limit": limit, "after": after})

    def operation(self, operation_id: str) -> dict[str, Any]:
        return self.request("GET", "/api/operations/" + _path_id(operation_id))

    def cancel(self, operation_id: str, body: Mapping[str, Any]) -> dict[str, Any]:
        return self.request("POST", f"/api/operations/{_path_id(operation_id)}/cancel", dict(body))

    def stop(self, portal_id: str, body: Mapping[str, Any]) -> dict[str, Any]:
        return self.request("POST", f"/api/portals/{_path_id(portal_id)}/stop", dict(body))

    def send(self, method: str, path: str, body: Mapping[str, Any]) -> dict[str, Any]:
        """Replay a retained outbox entry exactly as it was first persisted."""

        if method != "POST" or not re.fullmatch(r"/api/(builds|portals|operations/[A-Fa-f0-9-]{36}/cancel|portals/[A-Fa-f0-9-]{36}/stop)", path):
            raise SimPortalError("Retained SimPortal request is not a known mutation", code="invalid_request")
        return self.request(method, path, dict(body))


def _path_id(value: str) -> str:
    if not is_uuid(value):
        raise SimPortalError("SimPortal identifier is not a UUID", code="invalid_request")
    return value

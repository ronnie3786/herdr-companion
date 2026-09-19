"""HTTP server for the Code Factory dashboard: one static page plus a small JSON API.

The server runs ``http.server.ThreadingHTTPServer`` on a daemon thread and reads the
ledger through the shared ``CodeFactoryStore``. Actions (retry, skip, clean up,
release now) are delegated to the pipeline's ``CodeFactory.action`` method; the
server never mutates state itself. When a bearer ``token`` is configured every
``/api/*`` request must carry it (constant-time comparison); the HTML page is always
served so the browser can prompt for the token.

Browser-facing hardening that applies even without a token: requests whose ``Host``
names anything but this dashboard are refused (DNS rebinding), cross-site requests
are refused by ``Sec-Fetch-Site``/``Origin`` (CSRF), ``POST`` bodies must be
``application/json`` (no "simple" cross-site forms), the page may not be framed, and
idle connections are closed after ``request_timeout`` seconds.
"""

from __future__ import annotations

import hmac
import ipaddress
import json
import os
import re
import socket
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence
from urllib.parse import urlsplit

from ..child_environment import agent_environment
from .errors import CodeFactoryError
from .store import CodeFactoryStore, utc_now

DEFAULT_STATIC_PATH = Path(__file__).resolve().parent.parent / "static" / "code-factory.html"
CONTENT_SECURITY_POLICY = (
    "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; "
    "img-src data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
)
ISSUE_ACTIONS = ("retry", "skip", "cleanup", "release_now")
MAX_BODY_BYTES = 64 * 1024
REQUEST_TIMEOUT_SECONDS = 30.0
TAILSCALE_CANDIDATES = ("tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
HOST_PATTERN = re.compile(r"^[A-Za-z0-9.-]{1,253}$")
# Host names accepted in addition to the bound host: loopback aliases and tailnet MagicDNS
# (``tailscale serve`` fronts a loopback-bound dashboard under the machine's ts.net name).
ACCEPTED_HOST_SUFFIXES = (".localhost", ".ts.net")

_ISSUE_ROUTE = re.compile(r"^/api/issues/(\d{1,9})$")
_ACTION_ROUTE = re.compile(r"^/api/issues/(\d{1,9})/actions$")
_DISCONNECT_ERRORS = (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, TimeoutError)
_LOG_UNSAFE_RE = re.compile(r"[^\x20-\x7e]")

Logger = Callable[[str], None]


def tailscale_ipv4(
    runner: Callable[..., Any] = subprocess.run,
    *,
    environ: Mapping[str, str] | None = None,
) -> tuple[str | None, str]:
    """Ask the Tailscale CLI for this machine's IPv4 address.

    Tries ``tailscale`` on ``PATH`` and then the macOS app bundle binary. Returns
    ``(address, detail)`` where ``address`` is ``None`` when neither answered; the
    detail explains each failed attempt so ``doctor`` can print it. The child never
    inherits ``HERDR_*`` settings (tokens may arrive through the environment).
    """
    env = agent_environment(environ if environ is not None else os.environ, integration=False)
    failures: list[str] = []
    for binary in TAILSCALE_CANDIDATES:
        try:
            result = runner([binary, "ip", "-4"], capture_output=True, text=True, timeout=15, env=env)
        except (OSError, subprocess.TimeoutExpired) as exc:
            failures.append(f"{binary}: {exc.__class__.__name__}")
            continue
        if result.returncode != 0:
            failures.append(f"{binary}: exit status {result.returncode}")
            continue
        stdout = result.stdout if isinstance(result.stdout, str) else ""
        first = stdout.strip().splitlines()[0].strip() if stdout.strip() else ""
        try:
            address = ipaddress.ip_address(first)
        except ValueError:
            failures.append(f"{binary}: no IPv4 address in output")
            continue
        if address.version == 4:
            return str(address), f"{binary} reported {address}"
        failures.append(f"{binary}: returned an IPv6 address")
    return None, "; ".join(failures) or "no Tailscale binary tried"


def resolve_dashboard_host(
    value: str,
    *,
    runner: Callable[..., Any] = subprocess.run,
    log: Logger | None = None,
    environ: Mapping[str, str] | None = None,
) -> str:
    """Turn the configured ``dashboard_host`` into a bindable address.

    ``"tailscale"`` asks the Tailscale CLI for the machine's IPv4 address (trying the
    PATH binary first, then the macOS app bundle) and falls back to loopback with a
    warning when neither answers. Any other value is used literally.
    """
    text = (value or "").strip()
    if text.lower() != "tailscale":
        return text or "127.0.0.1"
    address, detail = tailscale_ipv4(runner, environ=environ)
    if address is not None:
        return address
    if log is not None:
        log(f"warning: could not resolve the Tailscale IPv4 address ({detail}); binding 127.0.0.1")
    return "127.0.0.1"


def host_resolves(host: str) -> bool:
    """True when ``host`` is an IP literal or a name the resolver knows (no network for literals)."""
    text = (host or "").strip()
    if not text:
        return False
    try:
        ipaddress.ip_address(text)
        return True
    except ValueError:
        pass
    if not HOST_PATTERN.match(text):
        return False
    try:
        socket.getaddrinfo(text, None)
    except (OSError, UnicodeError):
        return False
    return True


def _format_origin(host: str, port: int) -> str:
    text = host
    if text in ("0.0.0.0", ""):
        text = "127.0.0.1"
    elif text == "::":
        text = "::1"
    if ":" in text and not text.startswith("["):
        text = f"[{text}]"
    return f"http://{text}:{port}/"


def _host_port(host: str, port: int) -> str:
    return f"[{host}]:{port}" if ":" in host and not host.startswith("[") else f"{host}:{port}"


def _host_name(header: str) -> str | None:
    """The lowercase host name of a ``Host`` header value (``None`` when unparsable)."""
    try:
        name = urlsplit("//" + header.strip()).hostname
    except ValueError:
        return None
    return name.rstrip(".").lower() if name else None


def _settings_summary(settings: Any) -> dict[str, Any]:
    if settings is None:
        return {}
    summary = getattr(settings, "public_summary", None)
    if callable(summary):
        value = summary()
        return dict(value) if isinstance(value, Mapping) else {}
    if isinstance(settings, Mapping):
        return {str(key): value for key, value in settings.items() if key != "dashboard_token"}
    return {}


class _DashboardHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, request: Any, client_address: Any) -> None:  # pragma: no cover - network noise
        import sys

        exc = sys.exc_info()[1]
        if isinstance(exc, _DISCONNECT_ERRORS):
            return
        super().handle_error(request, client_address)


class _DashboardHTTPServer6(_DashboardHTTPServer):
    address_family = socket.AF_INET6


def _server_class(host: str) -> type[_DashboardHTTPServer]:
    """Pick the address family so IPv6 literals and IPv6-only names bind."""
    try:
        version = ipaddress.ip_address(host.strip("[]")).version
    except ValueError:
        try:
            families = {info[0] for info in socket.getaddrinfo(host, None)}
        except (OSError, UnicodeError):
            families = set()
        version = 6 if socket.AF_INET6 in families and socket.AF_INET not in families else 4
    return _DashboardHTTPServer6 if version == 6 else _DashboardHTTPServer


class DashboardServer:
    """Serve ``static/code-factory.html`` and the ``/api`` routes on a background thread."""

    def __init__(
        self,
        store: CodeFactoryStore,
        factory: Any,
        *,
        host: str,
        port: int,
        token: str = "",
        static_path: str | Path = DEFAULT_STATIC_PATH,
        settings: Any = None,
        log: Logger | None = None,
        allowed_hosts: Sequence[str] = (),
        request_timeout: float = REQUEST_TIMEOUT_SECONDS,
    ):
        if not isinstance(host, str) or not host.strip():
            raise CodeFactoryError("dashboard host must be a non-empty string", code="invalid_settings")
        if isinstance(port, bool) or not isinstance(port, int) or not 0 <= port <= 65535:
            raise CodeFactoryError("dashboard port must be between 0 and 65535", code="invalid_settings")
        if not isinstance(token, str) or "\x00" in token or "\n" in token:
            raise CodeFactoryError("dashboard token must be a single-line string", code="invalid_settings")
        if isinstance(request_timeout, bool) or not isinstance(request_timeout, (int, float)) or request_timeout <= 0:
            raise CodeFactoryError("dashboard request timeout must be a positive number", code="invalid_settings")
        self.store = store
        self.factory = factory
        self.host = host.strip()
        self.port = port
        self.token = token
        self.static_path = Path(static_path)
        self.settings = settings
        self.request_timeout = float(request_timeout)
        self._allowed_hosts = {
            name.strip().rstrip(".").lower() for name in (self.host, *allowed_hosts)
            if isinstance(name, str) and name.strip()
        }
        self._log = log
        self._server: _DashboardHTTPServer | None = None
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()

    # -- lifecycle ----------------------------------------------------------------

    def start(self) -> "DashboardServer":
        """Bind the socket and serve on a daemon thread; safe to call once.

        Raises ``CodeFactoryError(code="dashboard_bind_failed")`` when the address
        cannot be bound (port in use, address not assigned, name not resolvable).
        """
        with self._lock:
            if self._server is not None:
                return self
            try:
                server = _server_class(self.host)((self.host, self.port), self._handler_class())
            except OSError as exc:
                detail = getattr(exc, "strerror", None) or str(exc) or exc.__class__.__name__
                raise CodeFactoryError(
                    f"could not bind the dashboard on {_host_port(self.host, self.port)}: {detail}",
                    code="dashboard_bind_failed",
                ) from exc
            self.port = int(server.server_address[1])
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.25},
                                      name="herdr-code-factory-dashboard", daemon=True)
            self._server = server
            self._thread = thread
            thread.start()
        self.log(f"dashboard listening on {self.url}")
        return self

    def stop(self) -> None:
        with self._lock:
            server, thread = self._server, self._thread
            self._server, self._thread = None, None
        if server is None:
            return
        server.shutdown()
        server.server_close()
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=5)

    @property
    def running(self) -> bool:
        return self._server is not None

    @property
    def url(self) -> str:
        return _format_origin(self.host, self.port)

    def log(self, message: str) -> None:
        if self._log is not None:
            try:
                self._log(message)
            except Exception:  # pragma: no cover - logging must never break serving
                pass

    # -- request helpers (called from handler threads) ----------------------------

    def authorized(self, header: str | None) -> bool:
        if not self.token:
            return True
        scheme, separator, candidate = (header or "").partition(" ")
        if not separator or scheme.lower() != "bearer":
            return False
        return hmac.compare_digest(candidate.strip().encode("utf-8"), self.token.encode("utf-8"))

    def host_allowed(self, header: str | None) -> bool:
        """Refuse ``Host`` names that are not this dashboard (defeats DNS rebinding).

        IP literals, ``localhost``, the bound/configured host names and tailnet
        MagicDNS names are accepted; a request without a ``Host`` header (HTTP/1.0)
        carries no name to rebind and passes.
        """
        if header is None or not header.strip():
            return True
        name = _host_name(header)
        if name is None:
            return False
        try:
            ipaddress.ip_address(name)
            return True
        except ValueError:
            pass
        return name in self._allowed_hosts or name == "localhost" or name.endswith(ACCEPTED_HOST_SUFFIXES)

    def cross_site_reason(self, headers: Mapping[str, str]) -> str | None:
        """Why a browser request is cross-site (``None`` when it is not, or not a browser).

        ``Sec-Fetch-Site`` is authoritative when present; otherwise ``Origin`` must
        match ``Host``. Requests with neither header (curl, urllib) are not CSRF.
        """
        site = headers.get("Sec-Fetch-Site")
        if site is not None:
            value = site.strip().lower()
            if value in ("same-origin", "none"):
                return None
            return f"cross-site requests are refused (Sec-Fetch-Site: {value[:40] or 'empty'})"
        origin = headers.get("Origin")
        if origin is None:
            return None
        host = (headers.get("Host") or "").strip().lower()
        try:
            parts = urlsplit(origin.strip())
        except ValueError:
            return "cross-site requests are refused (malformed Origin)"
        if parts.scheme in ("http", "https") and parts.netloc and parts.netloc.lower() == host:
            return None
        return "cross-site requests are refused (Origin does not match Host)"

    def page_bytes(self) -> bytes | None:
        try:
            return self.static_path.read_bytes()
        except OSError:
            return None

    def state(self) -> dict[str, Any]:
        snapshot = self.store.snapshot()
        daemon = snapshot.get("daemon")
        if not isinstance(daemon, dict):
            daemon = {}
        if not daemon.get("dashboardUrl"):
            daemon["dashboardUrl"] = self.url
        snapshot["daemon"] = daemon
        settings = _settings_summary(self.settings)
        settings["dashboardUrl"] = self.url
        snapshot["settings"] = settings
        return snapshot

    def issue_action(self, number: int, action: str) -> dict[str, Any]:
        if action not in ISSUE_ACTIONS:
            raise CodeFactoryError(f"action must be one of {', '.join(ISSUE_ACTIONS)}", code="invalid_request")
        if self.factory is None:
            raise CodeFactoryError("the pipeline is not running; actions are unavailable", code="unavailable")
        if self.store.get_issue(number) is None:
            raise CodeFactoryError(f"issue #{number} is not tracked", code="not_found")
        result = self.factory.action(number, action)
        issue = result if isinstance(result, dict) and result.get("number") == number else self.store.get_issue(number)
        payload: dict[str, Any] = {"ok": True, "action": action, "issue": issue}
        if isinstance(result, dict) and "queued" in result:
            payload["queued"] = bool(result["queued"])
        return payload

    def release_action(self) -> dict[str, Any]:
        if self.factory is None:
            raise CodeFactoryError("the pipeline is not running; actions are unavailable", code="unavailable")
        result = self.factory.action(None, "release_now")
        payload: dict[str, Any] = {"ok": True, "action": "release_now"}
        if isinstance(result, dict):
            payload["result"] = result
            if "releaseStarted" in result:
                payload["releaseStarted"] = bool(result["releaseStarted"])
        return payload

    # -- handler ------------------------------------------------------------------

    def _handler_class(self) -> type[BaseHTTPRequestHandler]:
        dashboard = self

        class DashboardHandler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            server_version = "HerdrCodeFactory/1"
            sys_version = ""
            timeout = dashboard.request_timeout

            # -- logging --------------------------------------------------------------

            def log_message(self, fmt: str, *args: Any) -> None:
                try:
                    text = fmt % args
                except (TypeError, ValueError):
                    text = fmt
                dashboard.log("http " + _LOG_UNSAFE_RE.sub("?", text))

            def log_request(self, code: Any = "-", size: Any = "-") -> None:
                try:
                    status = int(code)
                except (TypeError, ValueError):
                    status = 0
                if 200 <= status < 300 and self.command == "GET":
                    return  # the page polls every few seconds; successful reads are not news
                self.log_message('"%s" %s %s', self.requestline, status or code, size)

            def log_error(self, fmt: str, *args: Any) -> None:
                if fmt.startswith("Request timed out"):
                    return  # idle keep-alive connections closing is routine
                self.log_message(fmt, *args)

            # -- responses ----------------------------------------------------------

            def _headers(self) -> None:
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Content-Type-Options", "nosniff")
                if self.close_connection:
                    self.send_header("Connection", "close")

            def _json(self, payload: Mapping[str, Any], status: int = 200, *, extra: Mapping[str, str] | None = None) -> None:
                body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
                try:
                    self.send_response(status)
                    self.send_header("Content-Type", "application/json; charset=utf-8")
                    self.send_header("Content-Length", str(len(body)))
                    for name, value in (extra or {}).items():
                        self.send_header(name, value)
                    self._headers()
                    self.end_headers()
                    self.wfile.write(body)
                except _DISCONNECT_ERRORS:
                    self.close_connection = True

            def _error(self, status: int, code: str, message: str, *, extra: Mapping[str, str] | None = None) -> None:
                self._json({"ok": False, "error": {"code": code, "message": message}, "generatedAt": utc_now()},
                           status, extra=extra)

            def _html(self, body: bytes) -> None:
                try:
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("Content-Security-Policy", CONTENT_SECURITY_POLICY)
                    self.send_header("X-Frame-Options", "DENY")
                    self.send_header("Referrer-Policy", "no-referrer")
                    self._headers()
                    self.end_headers()
                    self.wfile.write(body)
                except _DISCONNECT_ERRORS:
                    self.close_connection = True

            def _json_content_type(self) -> bool:
                value = self.headers.get("Content-Type") or ""
                return value.split(";", 1)[0].strip().lower() == "application/json"

            def _read_json(self) -> dict[str, Any]:
                raw_length = self.headers.get("Content-Length", "0")
                try:
                    length = int(raw_length)
                except ValueError as exc:
                    self.close_connection = True
                    raise CodeFactoryError("Content-Length is invalid", code="invalid_request") from exc
                if length < 0 or length > MAX_BODY_BYTES:
                    self.close_connection = True  # the body stays unread; the connection cannot be reused
                    raise CodeFactoryError("request body exceeds 64 KiB", code="invalid_request")
                raw = self.rfile.read(length) if length else b""
                if not raw.strip():
                    return {}
                try:
                    payload = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                    raise CodeFactoryError("request body must be a JSON object", code="invalid_request") from exc
                if not isinstance(payload, dict):
                    raise CodeFactoryError("request body must be a JSON object", code="invalid_request")
                return payload

            def _drain(self) -> None:
                """Consume an unread request body so the keep-alive connection stays in sync."""
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                except ValueError:
                    length = -1
                if 0 < length <= MAX_BODY_BYTES:
                    self.rfile.read(length)
                elif length != 0:
                    self.close_connection = True  # too large or unknown: do not reuse the connection

            # -- routing ------------------------------------------------------------

            def _dispatch(self, method: str) -> None:
                try:
                    path = urlsplit(self.path).path or "/"
                except ValueError:
                    self._error(400, "invalid_request", "malformed request path")
                    return
                try:
                    if not dashboard.host_allowed(self.headers.get("Host")):
                        self._drain()
                        self._error(421, "misdirected_request",
                                    "the Host header does not name this dashboard; open it by its configured address")
                        return
                    if path in ("/", "/index.html"):
                        if method != "GET":
                            self._drain()
                            self._error(405, "method_not_allowed", "use GET for the dashboard page")
                            return
                        body = dashboard.page_bytes()
                        if body is None:
                            self._error(500, "static_missing", "the dashboard page is not installed")
                            return
                        self._html(body)
                        return
                    if not path.startswith("/api/"):
                        self._drain()
                        self._error(404, "not_found", "no such route")
                        return
                    reason = dashboard.cross_site_reason(self.headers)
                    if reason is not None:
                        self._drain()
                        self._error(403, "forbidden", reason)
                        return
                    if not dashboard.authorized(self.headers.get("Authorization")):
                        self._drain()
                        self._error(401, "unauthorized", "A valid bearer token is required",
                                    extra={"WWW-Authenticate": 'Bearer realm="Herdr Code Factory"'})
                        return
                    if method == "POST" and not self._json_content_type():
                        self._drain()
                        self._error(415, "unsupported_media_type", "POST bodies must be sent as application/json")
                        return
                    self._route_api(method, path)
                except CodeFactoryError as exc:
                    status = {"not_found": 404, "invalid_request": 400, "unavailable": 503}.get(exc.code, 400)
                    self._error(status, exc.code, str(exc))
                except _DISCONNECT_ERRORS:
                    self.close_connection = True
                    return
                except Exception as exc:  # pragma: no cover - defensive: never leak tracebacks
                    dashboard.log(f"error: {method} {path}: {exc.__class__.__name__}: {exc}")
                    self._error(500, "internal_error", "the dashboard hit an unexpected error")

            def _route_api(self, method: str, path: str) -> None:
                if path == "/api/state":
                    if method != "GET":
                        self._drain()
                        self._error(405, "method_not_allowed", "use GET for /api/state")
                        return
                    self._json(dashboard.state())
                    return
                issue_match = _ISSUE_ROUTE.match(path)
                if issue_match:
                    if method != "GET":
                        self._drain()
                        self._error(405, "method_not_allowed", "use GET for an issue")
                        return
                    number = int(issue_match.group(1))
                    detail = dashboard.store.issue_detail(number) if number > 0 else None
                    if detail is None:
                        self._error(404, "not_found", f"issue #{number} is not tracked")
                        return
                    self._json({"ok": True, "issue": detail})
                    return
                action_match = _ACTION_ROUTE.match(path)
                if action_match:
                    if method != "POST":
                        self._drain()
                        self._error(405, "method_not_allowed", "use POST for actions")
                        return
                    number = int(action_match.group(1))
                    body = self._read_json()
                    action = body.get("action")
                    if not isinstance(action, str) or action not in ISSUE_ACTIONS:
                        self._error(400, "invalid_action", f"action must be one of {', '.join(ISSUE_ACTIONS)}")
                        return
                    if number <= 0:
                        self._error(404, "not_found", "issue number must be positive")
                        return
                    self._json(dashboard.issue_action(number, action))
                    return
                if path == "/api/releases/retry":
                    if method != "POST":
                        self._drain()
                        self._error(405, "method_not_allowed", "use POST to retry a release")
                        return
                    self._read_json()
                    self._json(dashboard.release_action())
                    return
                self._drain()
                self._error(404, "not_found", "no such API route")

            def do_GET(self) -> None:
                self._dispatch("GET")

            def do_POST(self) -> None:
                self._dispatch("POST")

            def do_PUT(self) -> None:
                self._dispatch("PUT")

            def do_DELETE(self) -> None:
                self._dispatch("DELETE")

        return DashboardHandler


__all__ = [
    "CONTENT_SECURITY_POLICY",
    "DEFAULT_STATIC_PATH",
    "ISSUE_ACTIONS",
    "REQUEST_TIMEOUT_SECONDS",
    "DashboardServer",
    "host_resolves",
    "resolve_dashboard_host",
    "tailscale_ipv4",
]

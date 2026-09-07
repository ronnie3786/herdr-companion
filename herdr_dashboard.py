#!/usr/bin/env python3
"""Run the Herdr Harness backend on a Tailscale-ready address."""

from __future__ import annotations

import argparse
import ipaddress
import os
import sys
import webbrowser

from herdr_harness.client import HerdrClient
from herdr_harness.config import ConfigurationError, configure_environment, server_origin
from herdr_harness.connection_info import publish_connection
from herdr_harness.server import make_server
from herdr_harness.service import HerdrService


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Herdr Harness HTTP and SSE backend")
    parser.add_argument("--config", help="Private cluster TOML file (env: HERDR_CONFIG)")
    parser.add_argument("--machine", help="Machine ID in the cluster file (env: HERDR_MACHINE)")
    parser.add_argument("--host", default=os.environ.get("HERDR_HARNESS_HOST", "127.0.0.1"))
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("HERDR_HARNESS_PORT", "9092")),
    )
    parser.add_argument("--socket", dest="socket_path", default=None, help="Herdr API Unix socket")
    parser.add_argument("--session", default=None, help="Herdr named session")
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument(
        "--allow-insecure-local",
        action="store_true",
        help="Allow an unauthenticated loopback-only development server",
    )
    return parser


def _is_loopback(host: str) -> bool:
    if str(host).lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(str(host)).is_loopback
    except ValueError:
        return False


def main(argv: list[str] | None = None) -> int:
    try:
        configuration = configure_environment(argv)
        args = _parser().parse_args(argv)
    except (ConfigurationError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    if not 1 <= args.port <= 65535:
        print("error: port must be between 1 and 65535", file=sys.stderr)
        return 2
    api_token = os.environ.get("HERDR_HARNESS_API_TOKEN", "").strip()
    if not api_token and (not args.allow_insecure_local or not _is_loopback(args.host)):
        print(
            "error: set HERDR_HARNESS_API_TOKEN before starting the control API\n"
            "For loopback-only development, explicitly pass --allow-insecure-local.",
            file=sys.stderr,
        )
        return 2

    client = HerdrClient(socket_path=args.socket_path, session=args.session)
    service_environ = dict(configuration.environ)
    service_environ["HERDR_HARNESS_HOST"] = args.host
    service_environ["HERDR_HARNESS_PORT"] = str(args.port)
    for name in configuration.derived_urls:
        service_environ[name] = server_origin(args.host, args.port)
    service = HerdrService(client, environ=service_environ)
    service.configuration = configuration
    server = make_server(service, host=args.host, port=args.port)
    registration = None
    try:
        registration = publish_connection(
            socket_path=client.socket_path,
            host=str(server.server_address[0]),
            port=server.server_address[1],
            environ=service_environ,
        )
        service.start()
    except Exception:
        if registration is not None:
            registration.close()
        server.server_close()
        service.stop()
        raise

    local_url = f"http://localhost:{server.server_address[1]}"
    print(f"Herdr Harness: {local_url}")
    print(f"API:           {local_url}/api/v1")
    print(f"Herdr session: {client.session}")
    print(f"Herdr socket:  {client.socket_path}")
    if api_token:
        print("Authentication: bearer token required")
    else:
        print("Authentication: disabled by explicit loopback-only development override")
    print(f"Listening on {args.host}:{server.server_address[1]}")

    should_open = not args.no_browser and os.environ.get("HERDR_HARNESS_NO_BROWSER", "").lower() not in {
        "1",
        "true",
        "yes",
    }
    if should_open:
        webbrowser.open(local_url)

    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        print("\nShutting down Herdr Harness.")
    finally:
        server.shutdown()
        server.server_close()
        service.stop()
        if registration is not None:
            registration.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

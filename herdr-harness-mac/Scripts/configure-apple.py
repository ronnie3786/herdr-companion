#!/usr/bin/env python3
"""Generate ignored Apple build settings from the one private Herdr TOML file.

Machine addresses and app identities become part of local build artifacts; tokens,
SSH users/hosts, and provider credentials are never embedded in these resources.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import os
import plistlib
import re
import sys
import tempfile
from urllib.parse import urlsplit

if sys.version_info < (3, 11):
    raise SystemExit("Apple configuration requires Python 3.11 or newer; use the server virtual environment.")

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from herdr_harness.config import load_configuration  # noqa: E402


def identifier(value: object, name: str, *, empty: bool = False) -> str:
    text = str(value or "")
    if empty and not text:
        return ""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", text):
        raise ValueError(f"{name} must contain only letters, numbers, dots, and hyphens")
    return text


def write_private(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive random creation avoids following a pre-existing temporary symlink.
    fd, temporary_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)



def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--machine")
    args = parser.parse_args()
    config = load_configuration(path=args.config, machine=args.machine, resolve_secrets=False)
    apple = config.section("apple")
    prefix = identifier(apple.get("bundle_prefix", "org.herdr.companion"), "apple.bundle_prefix")
    mac_id = identifier(apple.get("mac_bundle_id", prefix + ".macos"), "apple.mac_bundle_id")
    ios_id = identifier(apple.get("ios_bundle_id", prefix + ".ios"), "apple.ios_bundle_id")
    widget_id = identifier(apple.get("widget_bundle_id", ios_id + ".widgets"), "apple.widget_bundle_id")
    if not widget_id.startswith(ios_id + "."):
        raise ValueError("apple.widget_bundle_id must start with the iOS bundle identifier and a dot")
    environment = str(apple.get("apns_environment", "development"))
    if environment not in ("development", "production"):
        raise ValueError("apple.apns_environment must be development or production")
    settings = {
        "HERDR_DEVELOPMENT_TEAM": identifier(apple.get("team_id"), "apple.team_id", empty=True),
        "HERDR_MAC_BUNDLE_ID": mac_id,
        "HERDR_IOS_BUNDLE_ID": ios_id,
        "HERDR_WIDGET_BUNDLE_ID": widget_id,
        "HERDR_KEYCHAIN_SERVICE": identifier(apple.get("keychain_service"), "apple.keychain_service", empty=True),
        "HERDR_LEGACY_KEYCHAIN_SERVICE": identifier(apple.get("legacy_keychain_service"), "apple.legacy_keychain_service", empty=True),
        "HERDR_TERMINAL_BUNDLE_ID": identifier(apple.get("terminal_bundle_id"), "apple.terminal_bundle_id", empty=True),
        "HERDR_APNS_ENVIRONMENT": environment,
    }
    domains = apple.get("associated_domains", [])
    if not isinstance(domains, list) or any(not isinstance(domain, str) or not re.fullmatch(r"applinks:[A-Za-z0-9*.-]+(?:\?mode=developer)?", domain) for domain in domains):
        raise ValueError("apple.associated_domains must be an array of applinks domain strings")
    machines = []
    for item in config.public_machines():
        # Build-only cluster nodes need no address in the native app roster.
        if not item.get("url"):
            continue
        url = urlsplit(item["url"])
        if url.username or url.password or url.query or url.fragment:
            raise ValueError("Machine URLs cannot contain credentials, queries, or fragments")
        if url.scheme != "https" and not (url.scheme == "http" and url.hostname in ("localhost", "127.0.0.1", "::1")):
            raise ValueError("Machine URLs require HTTPS except for loopback HTTP")
        machines.append({"id": item["id"], "name": item["name"], "urlString": item["url"], "role": item.get("role", "node")})
    for platform in ("mac", "ios"):
        project = ROOT / f"herdr-harness-{platform}"
        app = project / f"herdr-harness-{platform}"
        entitlements = plistlib.loads((app / f"herdr_harness_{platform}.entitlements").read_bytes())
        if domains or platform == "ios":
            entitlements["com.apple.developer.associated-domains"] = domains
        if platform == "ios":
            entitlements["aps-environment"] = environment
        values = {**settings, "HERDR_CODE_SIGN_ENTITLEMENTS": "Local.entitlements"}
        content = "// Generated from private cluster configuration. Do not commit.\n"
        content += "".join(f"{key} = {value}\n" for key, value in values.items())
        write_private(project / "Local.xcconfig", content.encode())
        write_private(project / "Local.entitlements", plistlib.dumps(entitlements))
        write_private(app / "HerdrBootstrap.plist", plistlib.dumps(machines))
    print("Generated local Apple settings and machine metadata for macOS and iOS; no tokens embedded.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        raise SystemExit(f"Apple configuration failed: {error}") from error

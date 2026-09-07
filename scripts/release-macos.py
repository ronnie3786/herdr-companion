#!/usr/bin/env python3
"""Prepare and publish sanitized, signed Mac updates for experimenters."""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION_FILE = ROOT / "release/macos.json"
REPOSITORY = "ronnie3786/herdr-companion"
BUNDLE_ID = "org.herdr.companion.macos"
FEED_TAG = "macos-updates"
FEED_URL = f"https://github.com/{REPOSITORY}/releases/download/{FEED_TAG}/appcast.xml"
PUBLIC_KEY = "kXHvYAhLjLOEfXqCkkRxJUsqAygWHtgzk82h6qOJNUQ="
SPARKLE_VERSION = "2.9.6"
# Extracted from the official archive, SHA25652bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192.
TOOL_HASHES = {
    "generate_appcast": "b3b54ba3fb85ef1f25eb2f5a9ad90c32ba6e71af777b181c50ffb5d860bac6b7",
    "generate_keys": "2d18ed3a9c744e58150513d9b2e3c2eb76fd0b9621e3e4678d46dd972547e8fe",
    "sign_update": "bfb52400c3da18bb4c251ac4818c2c2e1e31c2e649a45b31c11109b6e57b34ad",
}
SPARKLE_NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
LOCK_REF = "tags/macos-release-publish-lock"

class ReleaseError(ValueError):
    pass


def digest(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def command_environment(program: str) -> dict[str, str]:
    allowed = {"HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME", "DEVELOPER_DIR"}
    if Path(program).name == "gh":
        allowed |= {"GH_TOKEN", "GITHUB_TOKEN", "GH_CONFIG_DIR"}
    return {key: value for key, value in os.environ.items() if key in allowed}


def private_diagnostics(program, stdout=b"", stderr=b""):
    directory = Path(tempfile.mkdtemp(prefix="herdr-release-diagnostics-"))
    path = directory / "failure.log"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write((Path(program).name + "\n").encode())
        handle.write(stdout or b""); handle.write(b"\n"); handle.write(stderr or b"")
    return path


def run(argv, *, cwd=None, data=None, allowed=(0,), timeout=1800):
    argv = [str(item) for item in argv]
    try:
        result = subprocess.run(argv, cwd=cwd, input=data, capture_output=True,
                                env=command_environment(argv[0]), timeout=timeout)
    except subprocess.TimeoutExpired as error:
        path = private_diagnostics(argv[0], error.stdout, error.stderr)
        raise ReleaseError(f"{Path(argv[0]).name} timed out; private diagnostics: {path}") from None
    if result.returncode not in allowed:
        path = private_diagnostics(argv[0], result.stdout, result.stderr)
        raise ReleaseError(f"{Path(argv[0]).name} failed (exit {result.returncode}); private diagnostics: {path}")
    return result


def gh(*args, data=None):
    return run(["gh", *args], data=data, timeout=120).stdout


def api(endpoint, *, method="GET", payload=None):
    arguments = ["api", f"repos/{REPOSITORY}/{endpoint}", "--method", method]
    data = None
    if payload is not None:
        arguments += ["--input", "-"]
        data = json.dumps(payload).encode()
    raw = gh(*arguments, data=data)
    return json.loads(raw) if raw else None


def validate_version(value):
    if set(value) != {"version", "build", "channel", "preview"}:
        raise ReleaseError("Release version file has unexpected fields")
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", str(value["version"])):
        raise ReleaseError("Release version must be major.minor.patch")
    if type(value["build"]) is not int or not 1 <= value["build"] <= 2147483647:
        raise ReleaseError("Release build must be a positive increasing integer")
    if value["channel"] not in {"stable", "preview"} or type(value["preview"]) is not int:
        raise ReleaseError("Release channel must be stable or preview")
    if (value["channel"] == "stable" and value["preview"] != 0) or (value["channel"] == "preview" and value["preview"] < 1):
        raise ReleaseError("Preview builds require a positive preview number; stable builds use zero")
    return value


def next_version(current, part="minor", channel="stable"):
    current = validate_version(dict(current))
    if part == "build" and current["channel"] == channel == "stable":
        raise ReleaseError("A stable release needs a new minor or patch version; its existing tag is immutable")
    numbers = [int(item) for item in current["version"].split(".")]
    if part == "minor": numbers[1] += 1; numbers[2] = 0
    elif part == "patch": numbers[2] += 1
    elif part != "build": raise ReleaseError("Bump part must be minor, patch, or build")
    preview = (current["preview"] + 1 if part == "build" and current["channel"] == "preview" else 1) if channel == "preview" else 0
    return validate_version({"version": ".".join(map(str, numbers)), "build": current["build"] + 1, "channel": channel, "preview": preview})


def release_tag(version):
    validate_version(version)
    suffix = f"-beta.{version['preview']}" if version["channel"] == "preview" else ""
    return "macos-v" + version["version"] + suffix


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".release-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2, sort_keys=True); stream.write("\n")
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def release_settings(args):
    sys.path.insert(0, str(ROOT))
    from herdr_harness.config import load_configuration
    config = load_configuration(args.config, args.machine, resolve_secrets=False)
    settings = config.section("deployment").get("macos_release", {})
    if not isinstance(settings, dict): raise ReleaseError("deployment.macos_release must be a table")
    allowed = {"signing_mode", "signing_team", "signing_identity", "notary_profile", "notary_keychain", "sparkle_key_account", "sparkle_tools", "private_patterns_file"}
    if set(settings) - allowed: raise ReleaseError("Unknown deployment.macos_release field")
    if any(not isinstance(value, str) or not value or "\x00" in value or "\n" in value for value in settings.values()):
        raise ReleaseError("Release settings must be nonempty strings; use Keychain profile references, not secrets")
    settings = dict(settings)
    for field in ("sparkle_tools", "notary_keychain", "private_patterns_file"):
        if field in settings:
            path = Path(settings[field]).expanduser()
            if not path.is_absolute(): path = (config.path.parent if config.path else Path.cwd()) / path
            settings[field] = str(path.resolve())
    return settings


def signing_mode(settings):
    mode = settings.get("signing_mode", "developer-id")
    if mode not in ("development", "developer-id"):
        raise ReleaseError("signing_mode must be development or developer-id")
    return mode


def validate_signing_settings(settings):
    mode = signing_mode(settings)
    prefix = "Apple Development" if mode == "development" else "Developer ID Application"
    if not re.fullmatch(re.escape(prefix) + r": .+ \([A-Z0-9]{10}\)", settings.get("signing_identity", "")):
        raise ReleaseError(f"{mode} preparation requires a configured {prefix} identity")
    if mode == "development" and not re.fullmatch(r"[A-Z0-9]{10}", settings.get("signing_team", "")):
        raise ReleaseError("Development preparation requires the certificate signing_team (not its name suffix)")
    if mode == "developer-id" and not settings.get("notary_profile"):
        raise ReleaseError("Developer ID preparation requires a configured notarytool Keychain profile")


def release_signing_policy(settings):
    mode = signing_mode(settings)
    return {"mode": mode, "notarized": mode == "developer-id"}


def tools_path(args, settings):
    directory = Path(args.sparkle_tools or settings.get("sparkle_tools", "")).expanduser()
    if not directory.is_absolute(): raise ReleaseError("Specify an absolute --sparkle-tools directory from the official 2.9.6 distribution")
    for name, expected in TOOL_HASHES.items():
        path = directory / name
        if not path.is_file() or path.is_symlink() or digest(path) != expected:
            raise ReleaseError("Sparkle tools do not match the pinned official 2.9.6 distribution")
    return directory


def key_arguments(settings):
    return ["--account", settings.get("sparkle_key_account", "org.herdr.companion.macos.release")]


def notary_arguments(settings):
    arguments = ["--keychain-profile", settings["notary_profile"]]
    if settings.get("notary_keychain"):
        arguments += ["--keychain", str(Path(settings["notary_keychain"]).expanduser())]
    return arguments


def signing_preflight(settings, tools):
    validate_signing_settings(settings)
    identities = run(["security", "find-identity", "-v", "-p", "codesigning"]).stdout.decode()
    if '"' + settings["signing_identity"] + '"' not in identities:
        raise ReleaseError("Configured signing certificate/private key is unavailable")
    public_key = run([tools / "generate_keys", *key_arguments(settings), "-p"]).stdout.decode().strip()
    if public_key != PUBLIC_KEY: raise ReleaseError("Sparkle Keychain account does not match the pinned public key")
    if signing_mode(settings) == "developer-id":
        run(["xcrun", "notarytool", "history", *notary_arguments(settings), "--output-format", "json"], timeout=120)


def source_revision():
    if run(["git", "status", "--porcelain", "--untracked-files=normal"], cwd=ROOT).stdout.strip():
        raise ReleaseError("Commit all release changes before preparing from a clean source revision")
    return run(["git", "rev-parse", "HEAD"], cwd=ROOT).stdout.decode().strip()


def require_green_ci(source):
    runs = json.loads(gh("run", "list", "--repo", REPOSITORY, "--commit", source, "--workflow", "Verify", "--json", "headSha,status,conclusion", "--limit", "20"))
    if not runs or runs[0].get("headSha") != source or runs[0].get("status") != "completed" or runs[0].get("conclusion") != "success":
        raise ReleaseError("The latest Verify run for this exact source revision must have passed")


def read_feed():
    try:
        with urllib.request.urlopen(FEED_URL, timeout=30) as response:
            data = response.read(2 * 1024 * 1024 + 1)
    except urllib.error.HTTPError as error:
        if error.code == 404: return None
        raise ReleaseError("Cannot retrieve the current public appcast") from None
    if len(data) > 2 * 1024 * 1024: raise ReleaseError("Appcast exceeds the size limit")
    return data


def feed_items(data):
    if len(data) > 2 * 1024 * 1024: raise ReleaseError("Appcast exceeds the size limit")
    if b"<!DOCTYPE" in data.upper() or b"<!ENTITY" in data.upper(): raise ReleaseError("Appcast must not contain document type declarations")
    try: root = ET.fromstring(data)
    except ET.ParseError: raise ReleaseError("Appcast is not valid XML") from None
    items = root.findall("./channel/item")
    for item in items:
        build = item.findtext(SPARKLE_NS + "version", "")
        channel = item.findtext(SPARKLE_NS + "channel", "stable")
        enclosure = item.find("enclosure")
        if not build.isdecimal() or channel not in {"stable", "preview"} or enclosure is None:
            raise ReleaseError("Appcast contains an invalid version/channel/enclosure")
        version_pattern = r"[0-9]+\.[0-9]+\.[0-9]+(?:-beta\.[0-9]+)?"
        pattern = re.escape(f"https://github.com/{REPOSITORY}/releases/download/macos-v") + version_pattern + r"/Herdr-" + version_pattern + r"\.zip"
        if not re.fullmatch(pattern, enclosure.get("url", "")) or not enclosure.get(SPARKLE_NS + "edSignature"):
            raise ReleaseError("Appcast contains an unexpected or unsigned archive")
    return items


def assemble_feed(directory, version, tools, settings, previous=None):
    """Use official tools, retaining stable and preview items in one signed feed."""
    feed = directory / "appcast.xml"
    if previous:
        feed_items(previous)
        feed.write_bytes(previous)
        run([tools / "sign_update", *key_arguments(settings), "--verify", feed])
        if any(int(item.findtext(SPARKLE_NS + "version")) >= version["build"] for item in feed_items(previous)):
            raise ReleaseError("New build number must exceed every published stable and preview build")
    arguments = [tools / "generate_appcast", *key_arguments(settings), "--download-url-prefix",
                 f"https://github.com/{REPOSITORY}/releases/download/{release_tag(version)}/",
                 "--maximum-deltas", "0", "--maximum-versions", "0", "--embed-release-notes",
                 "--versions", str(version["build"]), "-o", feed]
    if version["channel"] == "preview": arguments += ["--channel", "preview"]
    run([*arguments, directory], timeout=180)
    run([tools / "sign_update", *key_arguments(settings), "--verify", feed])
    items = feed_items(feed.read_bytes())
    current = [item for item in items if item.findtext(SPARKLE_NS + "version") == str(version["build"])]
    if len(current) != 1 or current[0].findtext(SPARKLE_NS + "channel", "stable") != version["channel"]:
        raise ReleaseError("Generated appcast does not contain the expected release/channel")
    if previous:
        old_builds = {item.findtext(SPARKLE_NS + "version") for item in feed_items(previous)}
        if not old_builds.issubset({item.findtext(SPARKLE_NS + "version") for item in items}):
            raise ReleaseError("Generated appcast dropped an existing release")
    if version["channel"] == "preview":
        # The app's numeric marketing version remains suitable for Apple's tools;
        # the signed feed distinguishes consecutive previews for the updater UI.
        tree = ET.fromstring(feed.read_bytes())
        item = next(item for item in tree.findall("./channel/item")
                    if item.findtext(SPARKLE_NS + "version") == str(version["build"]))
        label = version["version"] + " Preview " + str(version["preview"])
        for key, value in ((SPARKLE_NS + "shortVersionString", label), ("title", "Herdr " + label)):
            node = item.find(key)
            if node is None: node = ET.SubElement(item, key)
            node.text = value
        ET.register_namespace("sparkle", SPARKLE_NS[1:-1])
        feed.write_bytes(ET.tostring(tree, encoding="utf-8", xml_declaration=True))
        run([tools / "sign_update", *key_arguments(settings), feed], timeout=180)
        run([tools / "sign_update", *key_arguments(settings), "--verify", feed])
    return feed


def privacy_module():
    spec = importlib.util.spec_from_file_location("public_source_check", ROOT / "scripts/check-public-source.py")
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def private_patterns(settings):
    reference = (settings or {}).get("private_patterns_file")
    if not reference: return []
    sys.path.insert(0, str(ROOT))
    from herdr_harness.secret_file import load_private_file_bytes
    raw = load_private_file_bytes(str(Path(reference).expanduser()), field="release privacy patterns", maximum_bytes=131072)
    values = json.loads(raw)
    if not isinstance(values, list) or any(not isinstance(value, str) for value in values):
        raise ReleaseError("Release privacy patterns must be a private JSON array of regular expressions")
    try: return [("private identifier", re.compile(value.encode(), re.I)) for value in values]
    except re.error: raise ReleaseError("A private release privacy expression is invalid") from None


def privacy_check(path, settings=None, certificate=None):
    if path.is_symlink(): raise ReleaseError("Artifact input must not be a symlink")
    checker = privacy_module(); extra = private_patterns(settings)
    files = [path] if path.is_file() else path.rglob("*")
    for file in files:
        if file.is_symlink():
            if not file.resolve().is_relative_to(path.resolve()): raise ReleaseError("Artifact symlink escapes its bundle")
            continue
        if file.is_file():
            content = file.read_bytes()
            # Only exact public certificate bytes in signed Mach-O code are
            # exempted. Names, paths, configuration, and resources are not.
            if certificate and content[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
                content = content.replace(certificate, b"")
            if checker.inspect(file.name, content, extra):
                raise ReleaseError("Artifact privacy audit failed; no matching values were printed")


def audit_app(app, version, settings, *, notarized=None):
    validate_signing_settings(settings)
    if notarized is None:
        notarized = signing_mode(settings) == "developer-id"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = {"CFBundleIdentifier": BUNDLE_ID, "CFBundleShortVersionString": version["version"],
                "CFBundleVersion": str(version["build"]), "SUFeedURL": FEED_URL, "SUPublicEDKey": PUBLIC_KEY,
                "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
                "SUEnableInstallerLauncherService": True, "SUAllowsAutomaticUpdates": False,
                "SUAutomaticallyUpdate": False, "SUSendProfileInfo": False,
                "HerdrMacKeychainBackend": "login", "HerdrUpdateBundleIdentifier": BUNDLE_ID}
    if any(info.get(key) != value for key, value in expected.items()): raise ReleaseError("App identity/version/updater settings do not match the public release")
    for key in ("HerdrLegacyKeychainService", "HerdrTerminalBundleIdentifier", "HerdrDemoServerURL"):
        if info.get(key) not in (None, ""): raise ReleaseError("Public app contains a private identity or endpoint override")
    if info.get("HerdrKeychainService") not in (None, "", BUNDLE_ID): raise ReleaseError("Public app has an unexpected Keychain service")
    if app.name != "Herdr.app": raise ReleaseError("Public update bundle must retain the canonical Herdr.app name")
    if list(app.rglob("HerdrBootstrap.plist")): raise ReleaseError("Public app contains a generated machine roster")
    for target in signing_targets(app):
        if not target.exists(): raise ReleaseError("A required Sparkle update helper is missing")
        run(["codesign", "--verify", "--strict", target])
        signature = run(["codesign", "-d", "--verbose=4", target]).stderr.decode()
        if "Authority=" + settings["signing_identity"] + "\n" not in signature:
            raise ReleaseError("App and every Sparkle helper must carry the configured code signature")
        if target == app and "runtime" not in signature: raise ReleaseError("Public app must use hardened runtime")
    run(["codesign", "--verify", "--deep", "--strict", app])
    with tempfile.TemporaryDirectory(prefix="herdr-public-certificate-") as temporary:
        prefix = Path(temporary) / "certificate"
        run(["codesign", "-d", "--extract-certificates=" + str(prefix), app])
        privacy_check(app, settings, certificate=Path(str(prefix) + "0").read_bytes())
    if notarized:
        run(["xcrun", "stapler", "validate", app])
        run(["spctl", "--assess", "--type", "execute", app])


def export_source(source, directory):
    data = run(["git", "archive", "--format=tar", source], cwd=ROOT).stdout
    import io
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        archive.extractall(directory, filter="data")
    if any(directory.rglob("Local.xcconfig")) or any(directory.rglob("HerdrBootstrap.plist")):
        raise ReleaseError("Clean source export contains private generated build inputs")


def signing_targets(app):
    framework = app / "Contents/Frameworks/Sparkle.framework"
    return [framework / "Versions/B/Autoupdate", framework / "Versions/B/Updater.app",
            framework / "Versions/B/XPCServices/Installer.xpc",
            framework / "Versions/B/XPCServices/Downloader.xpc", framework, app]


def certificate_identity(app):
    """Use Apple's certificate fingerprint selector, not an ambiguous display name."""
    with tempfile.TemporaryDirectory(prefix="herdr-signing-certificate-") as temporary:
        prefix = Path(temporary) / "certificate"
        run(["codesign", "-d", "--extract-certificates=" + str(prefix), app])
        # SHA-1 here identifies a local certificate to codesign; it does not sign updates.
        return hashlib.sha1(Path(str(prefix) + "0").read_bytes()).hexdigest().upper()


def sign_development_app(app):
    identity = certificate_identity(app)
    for target in signing_targets(app):
        signature = run(["codesign", "-d", "--verbose=2", target]).stderr.decode()
        match = re.search(r"^Identifier=([A-Za-z0-9_.-]+)$", signature, re.M)
        if not match: raise ReleaseError("Cannot determine a helper's signing identifier")
        # Pin the existing certificate without copying its personal common name into
        # designated requirements and enclosing resource manifests.
        requirement = (f'designated => identifier "{match[1]}" and anchor apple generic '
                       f'and certificate leaf = H"{identity}"')
        run(["codesign", "--force", "--sign", identity, "--options", "runtime",
             "--preserve-metadata=identifier,entitlements", "--requirements", "=" + requirement, target])


def export_app(work, team, settings):
    """Development archives need explicit inside-out helper signing, no Apple upload."""
    validate_signing_settings(settings)
    if signing_mode(settings) == "developer-id":
        options = work / "ExportOptions.plist"
        options.write_bytes(plistlib.dumps({"method": "developer-id", "teamID": team,
            "signingStyle": "manual", "signingCertificate": settings["signing_identity"]}))
        run(["xcodebuild", "-exportArchive", "-archivePath", work / "Herdr.xcarchive",
             "-exportPath", work / "export", "-exportOptionsPlist", options])
        exported = list((work / "export").glob("*.app"))
    else:
        exported = list((work / "Herdr.xcarchive/Products/Applications").glob("*.app"))
    if len(exported) != 1: raise ReleaseError("Archive export must produce exactly one Mac app")
    app = work / "Herdr.app"
    shutil.move(exported[0], app)
    if signing_mode(settings) == "development":
        sign_development_app(app)
    return app


def prepare(args):
    version = validate_version(json.loads(VERSION_FILE.read_text()))
    settings = release_settings(args); validate_signing_settings(settings)
    tools = tools_path(args, settings); signing_preflight(settings, tools)
    source = source_revision(); require_green_ci(source)
    output = args.output.expanduser().resolve()
    if output.exists(): raise ReleaseError("Preparation output already exists; select a fresh directory")
    notes = args.notes.read_bytes(); privacy_check(args.notes, settings)
    if len(notes) > 131072: raise ReleaseError("Release notes exceed the size limit")
    notes.decode("utf-8")
    previous = read_feed()
    output.mkdir(parents=True, mode=0o700)
    try:
        with tempfile.TemporaryDirectory(prefix="herdr-public-release-") as temporary:
            work = Path(temporary); checkout = work / "source"; checkout.mkdir(); export_source(source, checkout)
            project = checkout / "herdr-harness-mac/herdr-harness-mac.xcodeproj"
            team = settings["signing_team"] if signing_mode(settings) == "development" else settings["signing_identity"].rsplit("(", 1)[1][:-1]
            run(["xcodebuild", "-project", project, "-scheme", "herdr-harness-mac", "-configuration", "Release",
                 "-derivedDataPath", work / "DerivedData", "-archivePath", work / "Herdr.xcarchive", "CODE_SIGN_STYLE=Manual",
                 "CODE_SIGN_IDENTITY=" + settings["signing_identity"], "DEVELOPMENT_TEAM=" + team,
                 "MARKETING_VERSION=" + version["version"], "CURRENT_PROJECT_VERSION=" + str(version["build"]),
                 "HERDR_MAC_BUNDLE_ID=" + BUNDLE_ID, "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO", "ONLY_ACTIVE_ARCH=NO", "archive"])
            app = export_app(work, team, settings)
            # This gate runs before transmitting any artifact to Apple.
            audit_app(app, version, settings, notarized=False)
            archive = output / ("Herdr-" + release_tag(version).removeprefix("macos-v") + ".zip")
            run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive])
            if signing_mode(settings) == "developer-id":
                result = json.loads(run(["xcrun", "notarytool", "submit", archive, *notary_arguments(settings), "--wait", "--output-format", "json"]).stdout)
                if result.get("status") != "Accepted": raise ReleaseError("Apple notarization was not accepted")
                run(["xcrun", "stapler", "staple", app]); audit_app(app, version, settings)
                archive.unlink(); run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive])
        notes_file = archive.with_suffix(".md"); notes_file.write_bytes(notes)
        feed = assemble_feed(output, version, tools, settings, previous)
        payload_names = [archive.name, notes_file.name, "appcast.xml"]
        metadata = {"schema": 1, "source": source, "tag": release_tag(version), "release": version,
                    "signing": release_signing_policy(settings),
                    "bundle_id": BUNDLE_ID, "sparkle": SPARKLE_VERSION, "feed_url": FEED_URL,
                    "public_key": PUBLIC_KEY, "archive": archive.name, "notes": notes_file.name,
                    "previous_feed_sha256": hashlib.sha256(previous).hexdigest() if previous else None,
                    "payloads": {name: digest(output / name) for name in payload_names}}
        write_json(output / "release.json", metadata)
        signature = run([tools / "sign_update", *key_arguments(settings), "-p", output / "release.json"]).stdout.decode().strip()
        (output / "release.json.ed25519").write_text(signature + "\n")
        asset_names = [*payload_names, "release.json", "release.json.ed25519"]
        sums = {name: digest(output / name) for name in asset_names}
        (output / "SHA256SUMS").write_text("".join(f"{value}  {name}\n" for name, value in sums.items()))
        sums["SHA256SUMS"] = digest(output / "SHA256SUMS")
        manifest = {**metadata, "assets": sums}
        write_json(output / "prepared.json", manifest)
        print(json.dumps({"ok": True, "prepared": str(output / "prepared.json"), "tag": manifest["tag"], "published": False}))
    except Exception:
        # Retain local evidence, but never mark a failed preparation publishable.
        (output / "prepared.json").unlink(missing_ok=True)
        raise


def safe_zip(archive, destination):
    with zipfile.ZipFile(archive) as zipped:
        entries = zipped.infolist()
        if len(entries) > 100000 or sum(item.file_size for item in entries) > 2 * 1024 ** 3:
            raise ReleaseError("Archive exceeds safety bounds")
        members = {}; links = {}
        for item in entries:
            path = PurePosixPath(item.filename)
            if path.is_absolute() or ".." in path.parts or not path.parts or str(path) in members:
                raise ReleaseError("Archive has an unsafe or duplicate path")
            if path.parts[0] == "__MACOSX":
                if len(path.parts) > 1 and path.parts[1] not in {"Herdr.app", "._Herdr.app"}:
                    raise ReleaseError("Archive contains unrelated resource metadata")
            elif path.parts[0] != "Herdr.app":
                raise ReleaseError("Archive contains a payload outside Herdr.app")
            members[str(path)] = item
            if stat.S_ISLNK(item.external_attr >> 16):
                if item.file_size > 4096: raise ReleaseError("Archive symlink exceeds safety bounds")
                target = zipped.read(item).decode()
                if not target or "\x00" in target or PurePosixPath(target).is_absolute():
                    raise ReleaseError("Archive symlink has an unsafe target")
                links[str(path)] = target
        for name in members:
            for parent in PurePosixPath(name).parents:
                ancestor = members.get(str(parent))
                if str(parent) in links or (ancestor is not None and not ancestor.is_dir()):
                    raise ReleaseError("Archive path traverses a non-directory member")
        # Resolve the complete graph, including chains such as Framework/Versions/
        # Current, in scratch metadata before extracting any archive payload.
        with tempfile.TemporaryDirectory(prefix="herdr-archive-links-") as temporary:
            scratch = Path(temporary).resolve()
            for name, target in links.items():
                link = scratch / name
                link.parent.mkdir(parents=True, exist_ok=True)
                link.symlink_to(target)
            for name in links:
                try: resolved = (scratch / name).resolve()
                except (OSError, RuntimeError): raise ReleaseError("Archive symlink graph is cyclic or invalid") from None
                if not resolved.is_relative_to(scratch): raise ReleaseError("Archive symlink escapes extraction root")
    run(["ditto", "-x", "-k", archive, destination])


def verify_prepared(path, tools, settings):
    manifest = json.loads(path.read_text()); directory = path.parent
    version = validate_version(manifest["release"])
    if manifest.get("signing", {"mode": "developer-id", "notarized": True}) != release_signing_policy(settings):
        raise ReleaseError("Prepared signing policy differs from the configured publisher")
    if manifest.get("schema") != 1 or manifest.get("tag") != release_tag(version) or manifest.get("bundle_id") != BUNDLE_ID or manifest.get("public_key") != PUBLIC_KEY or manifest.get("feed_url") != FEED_URL:
        raise ReleaseError("Prepared release manifest has an unexpected identity")
    if not re.fullmatch(r"[0-9a-f]{40}", manifest.get("source", "")): raise ReleaseError("Prepared source revision is invalid")
    for name, expected in manifest["assets"].items():
        if Path(name).name != name or (directory / name).is_symlink() or digest(directory / name) != expected:
            raise ReleaseError("Prepared release asset changed")
    required = {manifest["archive"], manifest["notes"], "appcast.xml", "release.json", "release.json.ed25519", "SHA256SUMS"}
    if set(manifest["assets"]) != required: raise ReleaseError("Prepared asset allowlist is invalid")
    signed_metadata = json.loads((directory / "release.json").read_text())
    if signed_metadata != {key: value for key, value in manifest.items() if key != "assets"}:
        raise ReleaseError("Prepared manifest differs from the signed release metadata")
    signature = (directory / "release.json.ed25519").read_text().strip()
    run([tools / "sign_update", *key_arguments(settings), "--verify", directory / "release.json", signature])
    if signed_metadata["payloads"] != {name: manifest["assets"][name] for name in (manifest["archive"], manifest["notes"], "appcast.xml")}:
        raise ReleaseError("Signed payload hashes differ from prepared assets")
    run([tools / "sign_update", *key_arguments(settings), "--verify", directory / "appcast.xml"])
    items = feed_items((directory / "appcast.xml").read_bytes())
    item = next((item for item in items if item.findtext(SPARKLE_NS + "version") == str(version["build"])), None)
    expected_url = f"https://github.com/{REPOSITORY}/releases/download/{manifest['tag']}/{manifest['archive']}"
    if item is None or item.find("enclosure").get("url") != expected_url: raise ReleaseError("Appcast/archive identity mismatch")
    signature = item.find("enclosure").get(SPARKLE_NS + "edSignature")
    run([tools / "sign_update", *key_arguments(settings), "--verify", directory / manifest["archive"], signature])
    with tempfile.TemporaryDirectory(prefix="herdr-release-verify-") as temporary:
        extracted = Path(temporary); safe_zip(directory / manifest["archive"], extracted)
        apps = list(extracted.glob("*.app"))
        if len(apps) != 1: raise ReleaseError("Release archive must contain one app")
        audit_app(apps[0], version, settings)
    for name in required - {manifest["archive"]}: privacy_check(directory / name, settings)
    return manifest


def tag_commit(tag):
    result = run(["gh", "api", f"repos/{REPOSITORY}/git/ref/tags/{tag}"], allowed=(0, 1), timeout=60)
    if result.returncode:
        if b"HTTP 404" in result.stderr: return None
        raise ReleaseError("Could not verify release tag availability")
    obj = json.loads(result.stdout)["object"]
    for _ in range(4):
        if obj["type"] == "commit": return obj["sha"]
        if obj["type"] != "tag": break
        obj = api("git/tags/" + obj["sha"])["object"]
    raise ReleaseError("Release tag does not resolve to a commit")


def verify_remote_assets(release, manifest, *, complete):
    remote = {item["name"]: item for item in release.get("assets", [])}
    expected = manifest["assets"]
    if set(remote) - set(expected) or (complete and set(remote) != set(expected)):
        raise ReleaseError("Existing release has an unexpected asset set")
    if any(remote[name].get("digest") != "sha256:" + expected[name] for name in remote):
        raise ReleaseError("Existing release assets differ; versioned assets will not be overwritten")
    if release.get("prerelease") != (manifest["release"]["channel"] == "preview"):
        raise ReleaseError("Existing release channel differs from the prepared release")
    return set(expected) - set(remote)


def publish(args):
    settings = release_settings(args); validate_signing_settings(settings)
    tools = tools_path(args, settings); signing_preflight(settings, tools)
    path = args.manifest.expanduser().resolve(); manifest = verify_prepared(path, tools, settings)
    require_green_ci(manifest["source"])
    # A remote Git ref serializes publishers across machines. Never steal a lock.
    api("git/refs", method="POST", payload={"ref": "refs/" + LOCK_REF, "sha": manifest["source"]})
    try:
        current = read_feed(); prepared_feed = (path.parent / "appcast.xml").read_bytes()
        current_hash = hashlib.sha256(current).hexdigest() if current else None
        restoring_missing = bool(current is None and manifest["previous_feed_sha256"] is not None
                                 and getattr(args, "restore_missing_feed", False))
        if current != prepared_feed and current_hash != manifest["previous_feed_sha256"] and not restoring_missing:
            raise ReleaseError("Feed changed since preparation; prepare again, or inspect a missing feed before explicit restoration")
        releases = json.loads(gh("release", "list", "--repo", REPOSITORY, "--limit", "1000", "--json", "tagName"))
        tags = {item["tagName"] for item in releases}
        target = tag_commit(manifest["tag"])
        if restoring_missing and (target != manifest["source"] or manifest["tag"] not in tags):
            raise ReleaseError("Missing feed restoration requires the exact version to be published already")
        if target is None:
            api("git/refs", method="POST", payload={"ref": "refs/tags/" + manifest["tag"], "sha": manifest["source"]})
        elif target != manifest["source"]:
            raise ReleaseError("Release tag points at a different source; it will not be moved")
        if FEED_TAG in tags:
            rolling = api("releases/tags/" + FEED_TAG)
            if rolling.get("immutable") or rolling.get("draft") or not rolling.get("prerelease"):
                raise ReleaseError("Rolling feed release must be mutable, published, and marked prerelease")
        else:
            gh("release", "create", FEED_TAG, "--repo", REPOSITORY, "--target", manifest["source"], "--prerelease", "--latest=false", "--title", "Mac update feed", "--notes", "Signed stable and preview update metadata. This feed release is not an application download.")
            if api("releases/tags/" + FEED_TAG).get("immutable"):
                raise ReleaseError("Repository immutability prevents rolling feed updates; configure hosting before publishing")
        if manifest["tag"] not in tags:
            arguments = ["release", "create", manifest["tag"], "--repo", REPOSITORY, "--verify-tag", "--draft", "--latest=false", "--title", "Herdr " + manifest["tag"].removeprefix("macos-v"), "--notes-file", str(path.parent / manifest["notes"])]
            if manifest["release"]["channel"] == "preview": arguments += ["--prerelease"]
            gh(*arguments)
        existing = api("releases/tags/" + manifest["tag"])
        if restoring_missing and existing.get("draft"):
            raise ReleaseError("Missing feed restoration cannot publish a draft version")
        missing = verify_remote_assets(existing, manifest, complete=not existing.get("draft"))
        if missing:
            gh("release", "upload", manifest["tag"], "--repo", REPOSITORY, *[str(path.parent / name) for name in sorted(missing)])
        uploaded = api("releases/tags/" + manifest["tag"])
        verify_remote_assets(uploaded, manifest, complete=True)
        if tag_commit(manifest["tag"]) != manifest["source"]:
            raise ReleaseError("Release tag changed during preparation; draft will not be published")
        if uploaded.get("draft"):
            gh("release", "edit", manifest["tag"], "--repo", REPOSITORY, "--draft=false", "--latest=" + ("true" if manifest["release"]["channel"] == "stable" else "false"))
        # Update discovery last. Only this dedicated rolling asset may be replaced.
        if current != prepared_feed:
            gh("release", "upload", FEED_TAG, "--repo", REPOSITORY, "--clobber", str(path.parent / "appcast.xml"))
        if read_feed() != prepared_feed: raise ReleaseError("Published feed verification failed; retry the same prepared manifest")
        print(json.dumps({"ok": True, "published": manifest["tag"], "feed": FEED_URL}))
    finally:
        api("git/refs/" + LOCK_REF, method="DELETE")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    bump = commands.add_parser("bump", help="Update public version metadata, then commit it before preparation")
    bump.add_argument("--part", choices=("minor", "patch", "build"), default="minor")
    bump.add_argument("--channel", choices=("stable", "preview"), default="stable")
    commands.add_parser("plan", help="Print only public release metadata; no Keychain access or network")
    for name in ("prepare", "publish"):
        sub = commands.add_parser(name)
        sub.add_argument("--config", type=Path)
        sub.add_argument("--machine")
        sub.add_argument("--sparkle-tools", type=Path)
        if name == "prepare":
            sub.add_argument("--notes", type=Path, required=True)
            sub.add_argument("--output", type=Path, required=True)
        else:
            sub.add_argument("manifest", type=Path)
            sub.add_argument("--restore-missing-feed", action="store_true",
                             help="After inspection, restore a missing feed only from an exactly matching published version")
    args = parser.parse_args(argv)
    try:
        if args.command == "bump":
            value = next_version(json.loads(VERSION_FILE.read_text()), args.part, args.channel); write_json(VERSION_FILE, value)
            print(json.dumps({"ok": True, "release": value, "commit_required": True})); return 0
        if args.command == "plan":
            value = validate_version(json.loads(VERSION_FILE.read_text()))
            print(json.dumps({"release": value, "tag": release_tag(value), "bundle_id": BUNDLE_ID, "feed_url": FEED_URL, "sparkle": SPARKLE_VERSION, "supported_signing_modes": ["development", "developer-id"], "signed_updates_required": True}, indent=2)); return 0
        (prepare if args.command == "prepare" else publish)(args)
        return 0
    except (ReleaseError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        message = str(error) if isinstance(error, ReleaseError) else type(error).__name__ + ": release operation failed; private values suppressed"
        print(message, file=sys.stderr)
        return 1

if __name__ == "__main__":
    raise SystemExit(main())

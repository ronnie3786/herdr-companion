"""First Mate simulator checkpoints and previews against a synthetic SimPortal.

Everything here is synthetic: an in-process fake of SimPortal's protocol-1 HTTP
and viewer WebSocket surfaces, throwaway app bundles, and temporary stores. No
real simulator, Xcode, or SimPortal is involved. The tests pin the contract in
docs/first-mate/simulator-previews.md: exact replay of persisted requests, a
pinned server identity, exact-UDID streaming that never claims shared focus,
and an idle/capacity policy that only ever stops Herdr's own previews.
"""
from __future__ import annotations

import json
import os
import plistlib
import re
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from herdr_harness import websocket_relay as ws
from herdr_harness.config import load_configuration
from herdr_harness.first_mate_runtime import DeferredOperation, FirstMateRuntime, _pi_command
from herdr_harness.first_mate_store import FirstMateError, FirstMateStore
from herdr_harness.server import make_handler
from herdr_harness.simulator_previews import (
    CheckpointContext,
    SimulatorPreviewError,
    SimulatorPreviews,
    _browser_links,
    sanitize_client_message,
)

TOKEN = "synthetic-simportal-token"
IPHONE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
IOS_26 = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
IOS_27 = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
STEPS = {
    "register_build": ["validating_build", "staging_build"],
    "start": ["validating", "staging_app", "creating_simulator", "booting", "installing", "launching", "checking_stream"],
    "stop": ["releasing_stream", "shutting_down"],
    "delete_simulator": ["deleting_simulator"],
}
TERMINAL = {"succeeded", "failed", "cancelled", "interrupted", "outcome_unknown"}


def now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


class FakeSimPortal:
    """The subset of SimPortal protocol 1 Herdr uses, with test controls."""

    def __init__(self, artifact_root: Path) -> None:
        self.server_id = str(uuid.uuid4())
        self.artifact_root = artifact_root
        self.admission = True
        self.builds: dict[str, dict] = {}
        self.portals: dict[str, dict] = {}
        self.operations: dict[str, dict] = {}
        self.receipts: dict[str, tuple[str, str]] = {}
        self.requests: list[tuple[str, str, dict | None]] = []
        self.lose_next: set[str] = set()
        # path prefix -> (status, body): refuse the next matching mutation before committing anything.
        self.fail_next: dict[str, tuple[int, dict]] = {}
        self.viewer_counts: dict[str, int] = {}
        self.device_states: dict[str, str] = {}
        self.ws_messages: list[dict] = []
        self.ws_headers: list[dict] = []
        # A real JPEG lets an actual client decode frames (scripts/simulator-preview-fixture.py).
        self.jpeg_frame: bytes | None = None
        self.input_jpeg_frame: bytes | None = None
        self.force_jpeg = False
        self.lock = threading.RLock()
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    @property
    def origin(self) -> str:
        return f"http://127.0.0.1:{self.httpd.server_port}"

    def close(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join()

    # Controls -----------------------------------------------------------------

    def operation(self, kind: str, *, request_id: str, portal_id: str | None = None, build_id: str | None = None) -> dict:
        op = {"id": str(uuid.uuid4()), "serverId": self.server_id, "requestId": request_id, "portalId": portal_id,
              "buildId": build_id, "kind": kind, "status": "queued", "step": None, "createdAt": now(),
              "updatedAt": now(), "cancelRequestedAt": None, "sequence": 1,
              "steps": [{"name": name, "state": "pending"} for name in STEPS[kind]], "error": None,
              "progress": {"fraction": None, "completedSteps": 0, "totalSteps": len(STEPS[kind])},
              "execution": {"workerActive": False, "acceptingWrites": True},
              "resources": {"owned": bool(portal_id), "udid": None, "simulatorName": None, "buildId": build_id,
                            "artifactDigest": None}}
        self.operations[op["id"]] = op
        return op

    def advance(self, operation_id: str, through: str) -> None:
        with self.lock:
            op = self.operations[operation_id]
            op["status"] = "running"
            for step in op["steps"]:
                step["state"] = "succeeded"
                op["step"] = step["name"]
                if op["kind"] == "start" and step["name"] == "creating_simulator":
                    portal = self.portals[op["portalId"]]
                    portal["udid"] = portal["udid"] or str(uuid.uuid4()).upper()
                    op["resources"]["udid"] = portal["udid"]
                    self.device_states[portal["udid"]] = "Shutdown"
                if op["kind"] == "start" and step["name"] == "booting":
                    self.device_states[self.portals[op["portalId"]]["udid"]] = "Booted"
                if step["name"] == through:
                    break
            if op["kind"] == "start":
                self.portals[op["portalId"]]["status"] = op["step"]
            op["sequence"] += 1

    def finish(self, operation_id: str, status: str = "succeeded", error: dict | None = None) -> None:
        with self.lock:
            op = self.operations[operation_id]
            if status == "succeeded":
                self.advance(operation_id, op["steps"][-1]["name"])
            op["status"], op["error"] = status, error
            op["sequence"] += 1
            if op["kind"] == "register_build":
                build = self.builds[op["buildId"]]
                build["status"] = "ready" if status == "succeeded" else status
                if status == "succeeded":
                    build["artifact"] = {"bundleId": "com.example.synthetic", "version": "1.4", "build": "212",
                                         "platform": "iPhoneSimulator", "architectures": ["arm64"],
                                         "minimumOS": "18.0", "digest": "sha256:" + "a" * 64,
                                         "digestFormat": "simportal-app-tree-v1", "bytes": 4096, "entries": 4,
                                         "sourceRevision": None, "provenance": "caller_reported", "stagedAt": now()}
            elif op["kind"] == "start":
                portal = self.portals[op["portalId"]]
                if status == "succeeded":
                    portal["status"] = "ready"
                    portal["viewerPath"] = "/d/" + portal["udid"]
                else:
                    portal["status"] = status
            elif op["kind"] == "stop":
                portal = self.portals[op["portalId"]]
                mode = op["mode"]
                portal["status"] = ("stopped" if mode == "shutdown" else "stream_released") if status == "succeeded" else status
                if mode == "shutdown" and status == "succeeded" and portal["udid"]:
                    self.device_states[portal["udid"]] = "Shutdown"

    def delete_simulator(self, portal_id: str) -> None:
        """What SimPortal's Machines page does to a shut-down preview's device."""

        with self.lock:
            portal = self.portals[portal_id]
            op = self.operation("delete_simulator", request_id=str(uuid.uuid4()), portal_id=portal_id,
                                build_id=portal["buildId"])
            op["status"], op["step"] = "succeeded", "deleting_simulator"
            op["steps"][0]["state"] = "succeeded"
            portal["operationId"], portal["status"] = op["id"], "simulator_deleted"
            self.device_states.pop(portal["udid"], None)

    def decorate(self, portal: dict) -> dict:
        links = None
        if portal.get("viewerPath"):
            links = {"path": portal["viewerPath"], "local": self.origin + portal["viewerPath"],
                     "tailnet": "https://simportal.example.invalid:8531" + portal["viewerPath"]}
        return {**portal, "links": links}

    def mutations(self, path_prefix: str) -> list[dict]:
        return [body for method, path, body in self.requests if method == "POST" and path.startswith(path_prefix)]

    # HTTP -------------------------------------------------------------------------

    def _handler(self):
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                return

            def _send(self, status: int, payload: dict) -> None:
                body = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _authorized(self) -> bool:
                if self.headers.get("Authorization") == "Bearer " + TOKEN:
                    return True
                self._send(401, {"error": "Not signed in."})
                return False

            def do_GET(self):
                if self.path.startswith("/ws/devices/"):
                    return self._viewer()
                if not self._authorized():
                    return
                path, _, query = self.path.partition("?")
                params = dict(part.split("=", 1) for part in query.split("&") if "=" in part)
                with fake.lock:
                    fake.requests.append(("GET", path, None))
                    if path == "/api/capabilities":
                        return self._send(200, {
                            "protocolVersion": 1, "serverId": fake.server_id,
                            "buildCatalog": {"version": 1, "enabled": True, "registrationCreatesSimulator": False,
                                             "scopeFilters": ["projectId", "featureId", "sessionId", "checkpointId"],
                                             "provenance": "caller_reported",
                                             "handoff": {"artifactRoots": [str(fake.artifact_root)],
                                                         "layout": "<project-id>/<feature-id>/<build-id>/<App>.app",
                                                         "format": "ios-simulator-app-directory"}},
                            "lifecycle": {"enabled": True, "sameHostArtifacts": True, "scopedViewerGrants": False,
                                          "limits": {"maxAppBytes": 2_000_000_000}},
                            "storage": {"totalBytes": 10**12, "usedOrReservedBytes": 1, "freeBytes": 9_000_000_000 if not fake.admission else 90_000_000_000,
                                        "minFreeBytes": 20_000_000_000, "admissionAllowed": fake.admission,
                                        "observedAt": now()},
                            "toolchain": {"developerDir": "/Applications/Xcode.app/Contents/Developer", "xcode": "26.2"},
                            "deviceTypes": [{"id": IPHONE, "name": "iPhone 17 Pro", "family": "iPhone"},
                                            {"id": "com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M3",
                                             "name": "iPad Air 11-inch (M3)", "family": "iPad"}],
                            "runtimes": [{"id": IOS_26, "name": "iOS 26.2", "version": "26.2", "platform": "iOS",
                                          "supportedDeviceTypes": [IPHONE]},
                                         {"id": IOS_27, "name": "iOS 27.0", "version": "27.0", "platform": "iOS",
                                          "supportedDeviceTypes": [IPHONE]},
                                         {"id": "com.apple.CoreSimulator.SimRuntime.watchOS-26-2", "name": "watchOS 26.2",
                                          "version": "26.2", "platform": "watchOS", "supportedDeviceTypes": []}],
                        })
                    if path == "/api/builds":
                        builds = [b for b in fake.builds.values() if b["scope"]["projectId"] == params.get("projectId")
                                  and b["scope"]["featureId"] == params.get("featureId")]
                        return self._send(200, {"builds": builds, "nextCursor": None})
                    match = re.fullmatch(r"/api/builds/([0-9a-f-]{36})", path)
                    if match and match.group(1) in fake.builds:
                        build = fake.builds[match.group(1)]
                        return self._send(200, {"build": build, "operation": fake.operations[build["operationId"]],
                                                "portals": [], "nextPortalCursor": None})
                    match = re.fullmatch(r"/api/portals/([0-9a-f-]{36})", path)
                    if match and match.group(1) in fake.portals:
                        portal = fake.portals[match.group(1)]
                        udid = portal.get("udid")
                        return self._send(200, {"portal": fake.decorate(portal), "operation": fake.operations[portal["operationId"]],
                                                "observation": {"observedAt": now(), "deviceState": fake.device_states.get(udid),
                                                                "inventoryError": None, "helperReady": False,
                                                                "viewerCount": fake.viewer_counts.get(udid, 0),
                                                                "lastFrameAt": None, "clientDisplayed": None}})
                    match = re.fullmatch(r"/api/operations/([0-9a-f-]{36})", path)
                    if match and match.group(1) in fake.operations:
                        return self._send(200, {"operation": fake.operations[match.group(1)]})
                return self._send(404, {"error": "not found", "code": "not_found"})

            def do_POST(self):
                if not self._authorized():
                    return
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length) or b"{}")
                path = self.path
                with fake.lock:
                    fake.requests.append(("POST", path, body))
                    refusal = next((prefix for prefix in fake.fail_next if path.startswith(prefix)), None)
                    if refusal is not None:
                        status, payload = fake.fail_next.pop(refusal)
                        return self._send(status, payload)
                    request_id = body.get("requestId")
                    canonical = json.dumps(body, sort_keys=True)
                    if request_id in fake.receipts:
                        saved, operation_id = fake.receipts[request_id]
                        if saved != canonical:
                            return self._send(409, {"error": "changed payload", "code": "request_conflict"})
                        return self._send(202, self._envelope(fake.operations[operation_id], replayed=True))
                    if path == "/api/builds":
                        build = {"id": body["buildId"], "serverId": fake.server_id, "name": body["name"],
                                 "scope": body["scope"], "source": {**body.get("source", {}), "provenance": "caller_reported"},
                                 "createdAt": now(), "updatedAt": now(), "status": "queued", "artifact": None,
                                 "toolchain": None, "appPath": body["appPath"]}
                        op = fake.operation("register_build", request_id=request_id, build_id=build["id"])
                        build["operationId"] = op["id"]
                        fake.builds[build["id"]] = build
                    elif path == "/api/portals":
                        build = fake.builds.get(body.get("buildId"))
                        if build is None or build["status"] != "ready":
                            return self._send(409, {"error": "build not ready", "code": "build_not_ready"})
                        portal_id = str(uuid.uuid4())
                        op = fake.operation("start", request_id=request_id, portal_id=portal_id, build_id=build["id"])
                        fake.portals[portal_id] = {"id": portal_id, "serverId": fake.server_id, "name": body["name"],
                                                   "simulatorName": f"{body['name']} [{portal_id}]", "buildId": build["id"],
                                                   "scope": build["scope"], "status": "queued", "operationId": op["id"],
                                                   "startOperationId": op["id"], "udid": None, "viewerPath": None,
                                                   "device": {"type": body["deviceType"], "runtime": body["runtime"]},
                                                   "owned": True, "createdAt": now(), "updatedAt": now()}
                    elif m := re.fullmatch(r"/api/portals/([0-9a-f-]{36})/stop", path):
                        portal = fake.portals[m.group(1)]
                        if fake.operations[portal["operationId"]]["status"] not in TERMINAL:
                            return self._send(409, {"error": "active", "code": "operation_active"})
                        if portal["status"] == "simulator_deleted":
                            return self._send(409, {"error": "deleted", "code": "simulator_deleted"})
                        op = fake.operation("stop", request_id=request_id, portal_id=portal["id"], build_id=portal["buildId"])
                        op["mode"] = body["mode"]
                        if body["mode"] == "stream":
                            op["steps"] = op["steps"][:1]
                        portal["operationId"] = op["id"]
                        portal["status"] = "stopping"
                    elif m := re.fullmatch(r"/api/operations/([0-9a-f-]{36})/cancel", path):
                        op = fake.operations[m.group(1)]
                        if op["status"] in TERMINAL:
                            return self._send(409, {"error": "terminal", "code": "operation_terminal"})
                        op["status"] = "cancelled" if op["status"] == "queued" else "cancel_requested"
                        if op["status"] == "cancelled" and op["portalId"]:
                            fake.portals[op["portalId"]]["status"] = "cancelled"
                        fake.receipts[request_id] = (canonical, op["id"])
                        return self._send(202, self._envelope(op, replayed=False))
                    else:
                        return self._send(404, {"error": "not found", "code": "not_found"})
                    fake.receipts[request_id] = (canonical, op["id"])
                    if path in fake.lose_next or any(path.startswith(prefix) for prefix in fake.lose_next):
                        fake.lose_next.discard(path)
                        # Committed, then the acknowledgement is lost on the way back.
                        self.close_connection = True
                        return
                    return self._send(202, self._envelope(op, replayed=False))

            def _envelope(self, op: dict, *, replayed: bool) -> dict:
                envelope = {"replayed": replayed, "portalId": op["portalId"], "buildId": op["buildId"],
                            "operationId": op["id"], "operation": op, "statusPath": f"/api/operations/{op['id']}",
                            "eventsPath": f"/api/operations/{op['id']}/events"}
                if op["portalId"]:
                    envelope["portal"] = fake.decorate(fake.portals[op["portalId"]])
                elif op["buildId"]:
                    envelope["build"] = fake.builds[op["buildId"]]
                return envelope

            def _viewer(self):
                key = ws.upgrade_key(self.headers)
                if key is None or self.headers.get("Authorization") != "Bearer " + TOKEN:
                    self.send_response(401)
                    self.end_headers()
                    return
                fake.ws_headers.append({"host": self.headers.get("Host"), "origin": self.headers.get("Origin")})
                self.send_response(101)
                self.send_header("Upgrade", "websocket")
                self.send_header("Connection", "Upgrade")
                self.send_header("Sec-WebSocket-Accept", ws.accept_value(key))
                self.end_headers()
                self.close_connection = True
                sock = ws.FrameSocket(self.connection, self.rfile, client=False, max_message=1 << 20)
                udid = self.path.rsplit("/", 1)[-1]
                with fake.lock:
                    fake.viewer_counts[udid] = fake.viewer_counts.get(udid, 0) + 1
                try:
                    sock.send_text(json.dumps({"type": "device", "device": {"udid": udid, "name": "Synthetic"}}))
                    while True:
                        opcode, payload = sock.receive()
                        message = json.loads(payload)
                        with fake.lock:
                            fake.ws_messages.append(message)
                        if message.get("type") == "hello" and (message.get("codec") == "jpeg" or fake.force_jpeg) and fake.jpeg_frame:
                            sock.send_text(json.dumps({"type": "ready", "width": 402, "height": 874, "codec": "jpeg"}))
                            for stamp in range(3):
                                sock.send(ws.OP_BINARY, b"\x04" + (stamp * 16_000).to_bytes(8, "big")
                                          + (402).to_bytes(2, "big") + (874).to_bytes(2, "big") + fake.jpeg_frame)
                        elif message.get("type") == "hello":
                            sock.send_text(json.dumps({"type": "ready", "width": 402, "height": 874, "codec": "h264"}))
                            codec = b"avc1.640c33"
                            sock.send(ws.OP_BINARY, b"\x02" + len(codec).to_bytes(2, "big") + codec
                                      + (402).to_bytes(2, "big") + (874).to_bytes(2, "big") + b"\x01synthetic-avcc")
                            sock.send(ws.OP_BINARY, b"\x03\x01" + (1234).to_bytes(8, "big") + os.urandom(70_000))
                        elif message.get("type") in {"touch", "button", "text"} and fake.input_jpeg_frame:
                            sock.send(ws.OP_BINARY, b"\x04" + (len(fake.ws_messages) * 16_000).to_bytes(8, "big")
                                      + (402).to_bytes(2, "big") + (874).to_bytes(2, "big") + fake.input_jpeg_frame)
                except (ws.WebSocketClosed, ws.WebSocketProtocolError, OSError, ValueError):
                    pass
                finally:
                    with fake.lock:
                        fake.viewer_counts[udid] -= 1

        return Handler


def make_app(root: Path, name: str = "Synthetic", platform: str = "iPhoneSimulator") -> Path:
    app = root / f"{name}.app"
    (app / "Assets").mkdir(parents=True)
    with (app / "Info.plist").open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": "com.example.synthetic", "CFBundleName": name,
                       "CFBundleShortVersionString": "1.4", "CFBundleVersion": "212", "CFBundleExecutable": name,
                       "MinimumOSVersion": "18.0", "CFBundleSupportedPlatforms": [platform]}, handle)
    (app / name).write_bytes(b"\xcf\xfa\xed\xfe synthetic executable")
    (app / "Assets" / "icon.txt").write_text("synthetic asset")
    return app


class SimulatorPreviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.artifacts = self.root / "simportal-builds"
        self.artifacts.mkdir()
        self.workspace = self.root / "project"
        self.workspace.mkdir()
        for args in (["init"], ["config", "user.email", "test@example.invalid"], ["config", "user.name", "Test"]):
            subprocess.run(["git", "-C", str(self.workspace), *args], capture_output=True, check=True)
        (self.workspace / "README.md").write_text("synthetic\n")
        # Like a real project, build output is ignored and never makes the tree dirty.
        (self.workspace / ".gitignore").write_text("*\n!.gitignore\n!README.md\n")
        subprocess.run(["git", "-C", str(self.workspace), "add", "."], capture_output=True, check=True)
        subprocess.run(["git", "-C", str(self.workspace), "commit", "-m", "synthetic"], capture_output=True, check=True)
        self.fake = FakeSimPortal(self.artifacts)
        self.store = FirstMateStore(self.root / "first-mate.sqlite3")
        self.feature = self.store.create_feature({"title": "Receipts", "goal": "Synthetic receipts",
                                                  "cwd": str(self.workspace), "request_id": "create"})
        self.clock = [1_900_000_000.0]
        self.notified: list[str] = []
        self.environ = {"HERDR_SIMPORTAL_URL": self.fake.origin, "HERDR_SIMPORTAL_TOKEN": TOKEN,
                        "HERDR_SIMPORTAL_INTAKE_ROOT": str(self.artifacts), "HERDR_STATE_DIR": str(self.root / "state"),
                        "HERDR_SIMPORTAL_MAX_RUNNING_PREVIEWS": "2", "HERDR_SIMPORTAL_IDLE_SHUTDOWN_MINUTES": "20"}
        self.previews = self.service()

    def tearDown(self):
        self.previews.stop()
        self.fake.close()
        self.store.close()
        self.temp.cleanup()

    def service(self, **overrides) -> SimulatorPreviews:
        return SimulatorPreviews({**self.environ, **overrides}, first_mate_store=self.store,
                                 notify=self.notified.append, clock=lambda: self.clock[0], sleep=self.tick_fake)

    def tick_fake(self, seconds: float = 1.0) -> None:
        """Time passes and SimPortal's worker settles pending registrations."""
        self.clock[0] += seconds
        for op in list(self.fake.operations.values()):
            if op["kind"] == "register_build" and op["status"] not in TERMINAL:
                self.fake.finish(op["id"])

    def context(self, **values) -> CheckpointContext:
        base = dict(feature_id=self.feature["id"], feature_title="Receipts", visit_id="fmv_" + "1" * 32,
                    visit_title="Implementation", assignment_id="fma_" + "2" * 32,
                    assignment_title="Implement receipts", native_session_id="0199a1b2-synthetic-session",
                    workspace=str(self.workspace), role="worker")
        base.update(values)
        return CheckpointContext(**base)

    def register(self, spool: str = "spool-1", **params) -> dict:
        app = params.pop("app", None) or make_app(self.workspace / "build/Build/Products/Debug-iphonesimulator")
        future = self.previews.submit_registration(spool, self.context(), {"app_path": str(app), **params})
        result = future.result(timeout=30)
        self.previews.release_registration(spool)
        return result

    def ready_preview(self, build_id: str, request: str = "open-1") -> dict:
        opened = self.previews.open_preview(self.feature["id"], build_id, request_id=request)
        preview = opened["preview"]
        portal_id = preview["portal_id"]
        self.fake.finish(self.fake.portals[portal_id]["operationId"])
        self.previews.tick()
        return self.previews.preview_detail(self.feature["id"], preview["id"])["preview"]

    # Configuration and discovery ------------------------------------------------------

    def test_configuration_section_maps_to_private_environment(self):
        token = self.root / "simportal-token"
        token.write_text(TOKEN + "\n")
        token.chmod(0o600)
        config = self.root / "config.toml"
        config.write_text(f"""version = 1
[simportal]
url = "http://127.0.0.1:4280"
token_file = "{token}"
intake_root = "~/.simportal/builds"
idle_shutdown_minutes = 30
max_running_previews = 3
[machines.desk]
name = "Desk"
role = "local"
[machines.desk.simportal]
device_type = "{IPHONE}"
""")
        config.chmod(0o600)
        resolved = load_configuration(config, machine="desk", environ={"HOME": str(self.root)}).environ
        self.assertEqual(resolved["HERDR_SIMPORTAL_URL"], "http://127.0.0.1:4280")
        self.assertEqual(resolved["HERDR_SIMPORTAL_TOKEN"], TOKEN)
        self.assertEqual(resolved["HERDR_SIMPORTAL_INTAKE_ROOT"], str(self.root / ".simportal/builds"))
        self.assertEqual(resolved["HERDR_SIMPORTAL_IDLE_SHUTDOWN_MINUTES"], "30")
        self.assertEqual(resolved["HERDR_SIMPORTAL_DEVICE_TYPE"], IPHONE)

    def test_unconfigured_service_is_inert_and_creates_no_ledger(self):
        previews = SimulatorPreviews({"HERDR_STATE_DIR": str(self.root / "inert")})
        status = previews.status()
        self.assertEqual(status["state"], "unconfigured")
        self.assertFalse(status["configured"])
        self.assertEqual(previews.feature_builds(self.feature["id"])["builds"], [])
        with self.assertRaises(SimulatorPreviewError) as caught:
            previews.open_preview(self.feature["id"], str(uuid.uuid4()), request_id="x")
        self.assertEqual(caught.exception.code, "simulator_unconfigured")
        self.assertFalse((self.root / "inert").exists())

    def test_status_pins_server_identity_and_refuses_a_replaced_server(self):
        status = self.previews.status(fresh=True)
        self.assertEqual(status["state"], "ready")
        self.assertTrue(status["registration_available"])
        self.assertEqual(status["pinned_server_id"], self.fake.server_id)
        self.assertEqual(status["default_device"], {"device_type": IPHONE, "device_type_name": "iPhone 17 Pro",
                                                    "runtime": IOS_27, "runtime_name": "iOS 27.0"})
        build = self.register()
        replaced = self.fake.server_id
        self.fake.server_id = str(uuid.uuid4())
        status = self.previews.status(fresh=True)
        self.assertEqual(status["state"], "server_changed")
        self.assertEqual(status["pinned_server_id"], replaced)
        with self.assertRaises(SimulatorPreviewError) as caught:
            self.previews.open_preview(self.feature["id"], build["build_id"], request_id="after-reset")
        self.assertEqual(caught.exception.code, "simulator_server_changed")
        listed = self.previews.feature_builds(self.feature["id"])["builds"]
        self.assertEqual(listed[0]["status"], "unavailable")
        self.assertFalse(listed[0]["launchable"])
        # Only an explicit operator pin accepts the new server; old records stay historical.
        repinned = self.service(HERDR_SIMPORTAL_SERVER_ID=self.fake.server_id)
        self.assertEqual(repinned.status(fresh=True)["state"], "ready")
        self.assertEqual(repinned.feature_builds(self.feature["id"])["builds"][0]["status"], "unavailable")
        repinned.stop()

    def test_low_storage_blocks_new_work_but_not_running_previews(self):
        build = self.register()
        preview = self.ready_preview(build["build_id"])
        self.fake.admission = False
        status = self.previews.status(fresh=True)
        self.assertEqual(status["state"], "storage_low")
        self.assertIn("9.0 GB free, 20 GB required", status["reason"])
        reused = self.previews.open_preview(self.feature["id"], build["build_id"], request_id="reuse-low")
        self.assertTrue(reused["reused"])
        self.assertEqual(reused["preview"]["id"], preview["id"])
        with self.assertRaises(SimulatorPreviewError) as caught:
            self.previews.submit_registration("spool-low", self.context(), {
                "app_path": str(make_app(self.workspace / "other/Debug-iphonesimulator"))}).result(timeout=10)
        self.assertEqual(caught.exception.code, "simulator_storage_low")

    # Registration -----------------------------------------------------------------------

    def test_registration_derives_scope_and_hands_off_an_exact_copy(self):
        result = self.register(label="Round 1: onboarding", hub_build_id="hub-build-7")
        self.assertEqual(result["status"], "ready")
        self.assertIn("not verification evidence", result["note"])
        [body] = self.fake.mutations("/api/builds")
        self.assertEqual(body["buildId"], result["build_id"])
        self.assertEqual(body["scope"], {"projectId": "herdr", "featureId": self.feature["id"],
                                         "sessionId": "0199a1b2-synthetic-session", "checkpointId": "fma_" + "2" * 32,
                                         "checkpointLabel": "Round 1: onboarding"})
        self.assertEqual(body["source"]["workingTree"], "clean")
        self.assertRegex(body["source"]["revision"], r"^[0-9a-f]{40}$")
        self.assertEqual(body["source"]["configuration"], "Debug")
        self.assertEqual(body["source"]["target"], "Synthetic")
        self.assertEqual(body["name"], "Synthetic · Round 1: onboarding")
        expected = self.artifacts / "herdr" / self.feature["id"] / result["build_id"] / "Synthetic.app"
        self.assertEqual(body["appPath"], str(expected))
        # SimPortal staged its own copy; Herdr's intake copy is released once it is ready.
        self.assertFalse(expected.parent.exists())
        build = self.previews.feature_builds(self.feature["id"])["builds"][0]
        self.assertEqual(build["hub_build_id"], "hub-build-7")
        self.assertEqual(build["app"]["version"], "1.4")
        self.assertEqual(build["digest"], "sha256:" + "a" * 64)
        self.assertTrue(build["launchable"])
        self.assertEqual(build["assignment_id"], "fma_" + "2" * 32)
        events = [e for e in self.store.get_events(self.feature["id"])["events"] if e["type"].startswith("simulator.")]
        self.assertEqual([e["type"] for e in events], ["simulator.build_ready"])
        self.assertEqual(self.notified, [self.feature["id"]])

    def test_registration_refuses_device_builds_links_and_foreign_paths(self):
        device = make_app(self.workspace / "device/Release-iphoneos", platform="iPhoneOS")
        with self.assertRaisesRegex(SimulatorPreviewError, "not an iOS Simulator build"):
            self.register(spool="device", app=device)
        linked = make_app(self.workspace / "linked/Debug-iphonesimulator")
        (linked / "alias").symlink_to(linked / "Assets")
        with self.assertRaisesRegex(SimulatorPreviewError, "symbolic link"):
            self.register(spool="linked", app=linked)
        elsewhere = make_app(self.root / "elsewhere")
        with patch.object(SimulatorPreviews, "_allowed_app_roots", lambda _self, context: [self.workspace]):
            with self.assertRaises(SimulatorPreviewError) as caught:
                self.register(spool="foreign", app=elsewhere)
        self.assertEqual(caught.exception.code, "simulator_app_outside_roots")
        with self.assertRaisesRegex(SimulatorPreviewError, "Unsupported field"):
            self.register(spool="forged", feature_id="fmf_other")
        self.assertEqual(self.fake.mutations("/api/builds"), [])

    def test_lost_acknowledgement_replays_the_identical_request(self):
        self.fake.lose_next.add("/api/builds")
        result = self.register()
        self.assertEqual(result["status"], "ready")
        sent = self.fake.mutations("/api/builds")
        self.assertEqual(len(sent), 2)
        self.assertEqual(sent[0], sent[1])
        self.assertEqual(len(self.fake.builds), 1)

    def test_restart_resumes_a_persisted_registration_without_a_second_build(self):
        app = make_app(self.workspace / "build/Debug-iphonesimulator")
        previews = self.service()
        # The first process persists the handoff, then dies before SimPortal answers.
        with patch.object(SimulatorPreviews, "_flush_outbox", lambda *args, **kwargs: True):
            with patch.object(SimulatorPreviews, "_observe_build", lambda *args, **kwargs: None):
                future = previews.submit_registration("spool-restart", self.context(), {"app_path": str(app)})
                with self.assertRaises(Exception):
                    future.result(timeout=0.2) if not future.done() else None
                    raise RuntimeError("still waiting")
        previews._stopping.set()
        previews.stop()
        restarted = self.service()
        result = restarted.submit_registration("spool-restart", self.context(), {"app_path": str(app)}).result(timeout=30)
        self.assertEqual(result["status"], "ready")
        self.assertEqual(len(self.fake.builds), 1)
        self.assertEqual(len({body["requestId"] for body in self.fake.mutations("/api/builds")}), 1)
        restarted.stop()

    # Previews -----------------------------------------------------------------------------

    def test_open_starts_an_exact_build_then_reuses_the_running_simulator(self):
        build = self.register()
        opened = self.previews.open_preview(self.feature["id"], build["build_id"], request_id="open-1")
        self.assertFalse(opened["reused"])
        [start] = self.fake.mutations("/api/portals")
        self.assertEqual(set(start), {"requestId", "name", "buildId", "deviceType", "runtime"})
        self.assertEqual((start["buildId"], start["deviceType"], start["runtime"]), (build["build_id"], IPHONE, IOS_27))
        preview = opened["preview"]
        self.assertEqual(preview["phase"], "starting")
        self.assertFalse(preview["stream_available"])
        op_id = self.fake.portals[preview["portal_id"]]["operationId"]
        self.fake.advance(op_id, "booting")
        detail = self.previews.preview_detail(self.feature["id"], preview["id"])["preview"]
        self.assertTrue(detail["stream_available"], detail)
        self.assertEqual(detail["phase"], "starting")
        self.fake.finish(op_id)
        detail = self.previews.preview_detail(self.feature["id"], preview["id"])
        self.assertEqual(detail["preview"]["phase"], "running")
        self.assertEqual(detail["build"]["id"], build["build_id"])
        self.assertEqual(detail["feature"]["label"], "Receipts")
        udid = detail["preview"]["udid"]
        self.assertEqual(detail["preview"]["browser_links"]["tailnet"], "https://simportal.example.invalid:8531/d/" + udid)
        again = self.previews.open_preview(self.feature["id"], build["build_id"], request_id="open-2")
        self.assertTrue(again["reused"])
        self.assertEqual(again["preview"]["id"], preview["id"])
        self.assertEqual(len(self.fake.mutations("/api/portals")), 1)
        replay = self.previews.open_preview(self.feature["id"], build["build_id"], request_id="open-1")
        self.assertEqual(replay["preview"]["id"], preview["id"])
        with self.assertRaises(SimulatorPreviewError) as caught:
            self.previews.open_preview(self.feature["id"], build["build_id"], request_id="open-1", device_type=IPHONE)
        self.assertEqual(caught.exception.code, "idempotency_conflict")
        self.assertEqual(self.previews.feature_builds(self.feature["id"])["selected_build_id"], build["build_id"])

    def test_capacity_shuts_down_the_least_recently_watched_idle_preview(self):
        builds = [self.register(spool=f"spool-{n}", app=make_app(self.workspace / f"b{n}/Debug-iphonesimulator", f"App{n}"))
                  for n in range(3)]
        first = self.ready_preview(builds[0]["build_id"], "open-a")
        self.clock[0] += 60
        second = self.ready_preview(builds[1]["build_id"], "open-b")
        self.fake.viewer_counts[second["udid"]] = 1  # someone is watching the newer one
        self.clock[0] += 60
        opened = self.previews.open_preview(self.feature["id"], builds[2]["build_id"], request_id="open-c")
        self.assertEqual([p["id"] for p in opened["stopped_to_make_room"]], [first["id"]])
        stops = self.fake.mutations("/api/portals/")
        self.assertEqual([(s["mode"]) for s in stops if "mode" in s], ["shutdown"])
        stopped = self.previews.preview_detail(self.feature["id"], first["id"])["preview"]
        self.assertEqual(stopped["stop_reason"], "capacity")
        # Every remaining simulator is in use: refuse instead of stopping a watched one.
        self.fake.viewer_counts[opened["preview"]["udid"] or "none"] = 1
        self.fake.finish(self.fake.portals[opened["preview"]["portal_id"]]["operationId"])
        self.previews.tick()
        detail = self.previews.preview_detail(self.feature["id"], opened["preview"]["id"])["preview"]
        self.fake.viewer_counts[detail["udid"]] = 1
        fourth = self.register(spool="spool-4", app=make_app(self.workspace / "b4/Debug-iphonesimulator", "App4"))
        with self.assertRaises(SimulatorPreviewError) as caught:
            self.previews.open_preview(self.feature["id"], fourth["build_id"], request_id="open-d")
        self.assertEqual(caught.exception.code, "simulator_capacity")
        self.assertEqual(len(caught.exception.details["running"]), 2)

    def test_idle_previews_shut_down_and_watched_ones_stay(self):
        build = self.register()
        preview = self.ready_preview(build["build_id"])
        self.fake.viewer_counts[preview["udid"]] = 1
        self.clock[0] += 3600
        self.previews._last_reap = 0
        self.previews.tick()
        self.assertEqual([b for b in self.fake.mutations("/api/portals/") if "mode" in b], [])
        self.fake.viewer_counts[preview["udid"]] = 0
        self.clock[0] += 19 * 60
        self.previews._last_reap = 0
        self.previews.tick()
        self.assertEqual([b for b in self.fake.mutations("/api/portals/") if "mode" in b], [])
        self.clock[0] += 2 * 60
        self.previews._last_reap = 0
        self.previews.tick()
        [stop] = [b for b in self.fake.mutations("/api/portals/") if "mode" in b]
        self.assertEqual(stop["mode"], "shutdown")
        self.fake.finish(self.fake.portals[preview["portal_id"]]["operationId"])
        self.previews.tick()
        detail = self.previews.preview_detail(self.feature["id"], preview["id"])["preview"]
        self.assertEqual((detail["phase"], detail["stop_reason"]), ("stopped", "idle"))

    def test_idle_policy_can_be_disabled(self):
        previews = self.service(HERDR_SIMPORTAL_IDLE_SHUTDOWN_MINUTES="0")
        self.previews.stop()
        self.previews = previews
        build = self.register()
        self.ready_preview(build["build_id"])
        self.clock[0] += 48 * 3600
        previews._last_reap = 0
        previews.tick()
        self.assertEqual([b for b in self.fake.mutations("/api/portals/") if "mode" in b], [])

    def test_stop_during_start_cancels_then_shuts_down_the_owned_simulator(self):
        build = self.register()
        preview = self.previews.open_preview(self.feature["id"], build["build_id"], request_id="open-1")["preview"]
        op_id = self.fake.portals[preview["portal_id"]]["operationId"]
        self.fake.advance(op_id, "installing")
        stopped = self.previews.stop_preview(self.feature["id"], preview["id"], request_id="stop-1")["preview"]
        self.assertEqual(stopped["phase"], "stopping")
        cancels = self.fake.mutations("/api/operations/")
        self.assertEqual(len(cancels), 1)
        self.assertEqual(self.fake.operations[op_id]["status"], "cancel_requested")
        self.fake.finish(op_id, "cancelled")
        self.previews.tick()
        [stop] = [b for b in self.fake.mutations("/api/portals/") if "mode" in b]
        self.assertEqual(stop["mode"], "shutdown")
        replay = self.previews.stop_preview(self.feature["id"], preview["id"], request_id="stop-1")
        self.assertEqual(replay["preview"]["id"], preview["id"])
        self.assertEqual(len([b for b in self.fake.mutations("/api/portals/") if "mode" in b]), 1)

    def test_explicit_stop_of_a_running_preview_is_durable_and_replayable(self):
        build = self.register()
        preview = self.ready_preview(build["build_id"])
        self.fake.lose_next.add(f"/api/portals/{preview['portal_id']}/stop")
        result = self.previews.stop_preview(self.feature["id"], preview["id"], request_id="stop-1", mode="shutdown")
        self.assertEqual(result["preview"]["phase"], "stopping")
        self.clock[0] += 5
        self.previews.tick()
        stops = [b for b in self.fake.mutations("/api/portals/") if "mode" in b]
        self.assertEqual(len(stops), 2)
        self.assertEqual(stops[0], stops[1])
        self.fake.finish(self.fake.portals[preview["portal_id"]]["operationId"])
        self.previews.tick()
        self.assertEqual(self.previews.preview_detail(self.feature["id"], preview["id"])["preview"]["phase"], "stopped")

    def test_default_policy_is_an_hour_and_four_simulators(self):
        environ = {k: v for k, v in self.environ.items()
                   if k not in {"HERDR_SIMPORTAL_MAX_RUNNING_PREVIEWS", "HERDR_SIMPORTAL_IDLE_SHUTDOWN_MINUTES"}}
        previews = SimulatorPreviews(environ, first_mate_store=self.store, clock=lambda: self.clock[0])
        try:
            self.assertEqual(previews.status(fresh=True)["policy"],
                             {"idle_shutdown_minutes": 60, "max_running_previews": 4})
        finally:
            previews.stop()

    def test_a_simulator_deleted_in_simportal_reads_as_stopped_and_opens_fresh(self):
        build = self.register()
        preview = self.ready_preview(build["build_id"])
        self.previews.stop_preview(self.feature["id"], preview["id"], request_id="stop-1", mode="shutdown")
        self.fake.finish(self.fake.portals[preview["portal_id"]]["operationId"])
        self.previews.tick()
        self.fake.delete_simulator(preview["portal_id"])
        self.clock[0] += 6  # the next observation after the companion's short cache
        detail = self.previews.preview_detail(self.feature["id"], preview["id"])["preview"]
        self.assertEqual((detail["phase"], detail["status"], detail["error"]), ("stopped", "simulator_deleted", None))
        self.assertFalse(detail["stream_available"])
        stops = len([b for b in self.fake.mutations("/api/portals/") if "mode" in b])
        self.previews.stop_preview(self.feature["id"], preview["id"], request_id="stop-2")
        self.assertEqual(len([b for b in self.fake.mutations("/api/portals/") if "mode" in b]), stops,
                         "nothing is left to stop")
        reopened = self.previews.open_preview(self.feature["id"], build["build_id"], request_id="open-2")
        self.assertFalse(reopened["reused"])
        self.assertNotEqual(reopened["preview"]["id"], preview["id"])

    def test_a_stop_refused_because_the_simulator_was_deleted_settles_without_an_error(self):
        build = self.register()
        preview = self.ready_preview(build["build_id"])
        # The stop request races a deletion on the Machines page (SimPortal refuses deleting
        # a booted device, so this only happens once it was shut down elsewhere).
        self.fake.device_states[preview["udid"]] = "Shutdown"
        self.fake.delete_simulator(preview["portal_id"])
        with self.previews._transaction() as db:
            db.execute("UPDATE sim_previews SET status='ready' WHERE id=?", (preview["id"],))
        self.previews._enqueue_stop(self.previews._row("SELECT * FROM sim_previews WHERE id=?", (preview["id"],)),
                                    mode="shutdown", reason="idle")
        row = self.previews._row("SELECT * FROM sim_previews WHERE id=?", (preview["id"],))
        self.assertEqual((row["status"], row["error_json"], row["pending_stop"]), ("simulator_deleted", None, None))
        self.assertEqual(self.previews._phase(row), "stopped")

    def test_a_stop_that_arrives_after_the_start_finished_is_still_sent(self):
        build = self.register()
        preview = self.previews.open_preview(self.feature["id"], build["build_id"], request_id="open-1")["preview"]
        start = self.fake.portals[preview["portal_id"]]["operationId"]
        self.fake.advance(start, "launching")
        # The cancel is lost to a transient error; by its retry the start has finished, and SimPortal
        # answers that a finished operation can't be cancelled.
        self.fake.fail_next["/api/operations/"] = (503, {"error": "busy", "code": "unavailable"})
        stopped = self.previews.stop_preview(self.feature["id"], preview["id"], request_id="stop-1")["preview"]
        self.assertEqual(stopped["phase"], "stopping")
        self.fake.finish(start)
        self.clock[0] += 5
        for _ in range(3):
            self.previews.tick()
        stops = [b for b in self.fake.mutations("/api/portals/") if "mode" in b]
        self.assertEqual([b["mode"] for b in stops], ["shutdown"], "the user's stop is sent once the start settled")
        row = self.previews._row("SELECT * FROM sim_previews WHERE id=?", (preview["id"],))
        self.assertIsNone(row["error_json"], "a start that simply finished first is not an error")
        self.fake.finish(self.fake.portals[preview["portal_id"]]["operationId"])
        self.previews.tick()
        self.assertEqual(self.previews.preview_detail(self.feature["id"], preview["id"])["preview"]["phase"], "stopped")

    def test_a_refused_or_unsettled_registration_releases_its_intake_copy(self):
        self.fake.fail_next["/api/builds"] = (400, {"error": "bad metadata", "code": "invalid_request"})
        refused = self.register(spool="refused")
        self.assertEqual(refused["status"], "failed")
        self.assertEqual(list(self.artifacts.rglob("*.app")), [], "a refused registration keeps nothing")
        # An interrupted registration is never resumed, so its intake copy goes too. This service's
        # time passes without SimPortal settling anything, so the test decides how it ends.
        app = make_app(self.workspace / "other/Build/Products/Debug-iphonesimulator")
        quiet = SimulatorPreviews(self.environ, first_mate_store=self.store, clock=lambda: self.clock[0],
                                  sleep=lambda seconds=1.0: self.clock.__setitem__(0, self.clock[0] + seconds))
        try:
            pending = quiet.submit_registration("interrupted", self.context(), {"app_path": str(app)}).result(timeout=30)
            quiet.release_registration("interrupted")
            self.assertEqual(pending["status"], "registering")
            self.assertEqual(len(list(self.artifacts.rglob("*.app"))), 1, "kept while SimPortal works on it")
            registered = self.fake.builds[pending["build_id"]]
            self.fake.finish(registered["operationId"], "interrupted",
                             {"code": "server_interrupted", "message": "Server stopped before completion."})
            quiet.tick()
            row = quiet._row("SELECT status FROM sim_builds WHERE build_id=?", (pending["build_id"],))
            self.assertEqual(row["status"], "interrupted")
            self.assertEqual(list(self.artifacts.rglob("*.app")), [])
        finally:
            quiet.stop()

    def test_a_start_refused_after_the_user_pressed_stop_ends_as_failed(self):
        build = self.register()
        self.fake.fail_next["/api/portals"] = (503, {"error": "busy", "code": "unavailable"})
        preview = self.previews.open_preview(self.feature["id"], build["build_id"], request_id="open-1")["preview"]
        self.previews.stop_preview(self.feature["id"], preview["id"], request_id="stop-1")
        self.fake.fail_next["/api/portals"] = (409, {"error": "not ready", "code": "build_not_ready"})
        self.clock[0] += 5
        self.previews.tick()
        row = self.previews._row("SELECT * FROM sim_previews WHERE id=?", (preview["id"],))
        self.assertIsNone(row["pending_stop"])
        self.assertEqual(self.previews._phase(row), "failed", "never stuck shutting down")

    def test_capacity_counts_only_previews_that_still_run(self):
        first, second, third = [self.register(spool=f"cap-{n}", app=make_app(self.workspace / f"c{n}/Debug-iphonesimulator", f"Cap{n}"))
                                for n in range(3)]
        p1 = self.ready_preview(first["build_id"], request="open-1")
        self.ready_preview(second["build_id"], request="open-2")
        # p1 was shut down outside Herdr since the last pass.
        portal = self.fake.portals[p1["portal_id"]]
        portal["status"] = "stopped"
        self.fake.device_states[portal["udid"]] = "Shutdown"
        opened = self.previews.open_preview(self.feature["id"], third["build_id"], request_id="open-3")
        self.assertEqual(opened["stopped_to_make_room"], [])
        self.assertEqual([b for b in self.fake.mutations("/api/portals/") if "mode" in b], [])

    def test_a_replaced_simportal_is_not_polled_for_old_work(self):
        build = self.register()
        preview = self.previews.open_preview(self.feature["id"], build["build_id"], request_id="open-1")["preview"]
        self.fake.advance(self.fake.portals[preview["portal_id"]]["operationId"], "booting")
        self.fake.server_id = str(uuid.uuid4())
        self.previews.status(fresh=True)
        before = len(self.fake.requests)
        busy = [self.previews.tick() for _ in range(3)]
        self.assertEqual(busy, [False, False, False])
        operation_reads = [path for method, path, _ in self.fake.requests[before:] if path.startswith("/api/operations/")]
        self.assertEqual(operation_reads, [])

    def test_labels_are_clipped_in_simportal_units(self):
        from herdr_harness.simulator_previews import _clip_utf16
        label = "🧪" * 90  # 90 code points, 180 UTF-16 units
        clipped = _clip_utf16(label, 160)
        self.assertLessEqual(len(clipped.encode("utf-16-le")) // 2, 160)
        self.assertTrue(clipped.endswith("…"))
        self.assertEqual(_clip_utf16("Round 1", 160), "Round 1")

    def test_catalog_sync_includes_same_scope_builds_and_cleanup(self):
        result = self.register()
        external_id = str(uuid.uuid4())
        self.fake.builds[external_id] = {
            "id": external_id, "serverId": self.fake.server_id, "name": "Hand-built", "status": "ready",
            "scope": {"projectId": "herdr", "featureId": self.feature["id"], "sessionId": "manual",
                      "checkpointId": "manual", "checkpointLabel": "Hand-built check"},
            "source": {"workingTree": "unknown"}, "createdAt": now(), "updatedAt": now(), "artifact": None,
            "operationId": self.fake.builds[result["build_id"]]["operationId"]}
        self.fake.builds[result["build_id"]]["status"] = "deleted"
        builds = {b["id"]: b for b in self.previews.feature_builds(self.feature["id"])["builds"]}
        self.assertEqual(builds[external_id]["origin"], "external")
        self.assertEqual(builds[external_id]["checkpoint_label"], "Hand-built check")
        self.assertEqual(builds[result["build_id"]]["status"], "deleted")
        self.assertFalse(builds[result["build_id"]]["launchable"])

    # Stream relay -------------------------------------------------------------------------

    def test_client_messages_are_filtered_to_viewer_input(self):
        hello = sanitize_client_message(b'{"type":"hello","codec":"h264","quality":"high","focus":true,"observe":false}')
        self.assertEqual(hello, {"type": "hello", "codec": "h264", "quality": "high", "observe": True, "focus": False})
        self.assertIsNone(sanitize_client_message(b'{"type":"focus"}'))
        self.assertIsNone(sanitize_client_message(b'{"type":"boot"}'))
        self.assertIsNone(sanitize_client_message(b'not json'))
        self.assertEqual(sanitize_client_message(b'{"type":"touch","phase":"began","x":1.4,"y":-2,"extra":1}'),
                         {"type": "touch", "phase": "began", "x": 1.0, "y": 0.0})
        self.assertIsNone(sanitize_client_message(b'{"type":"touch","phase":"hover","x":0.5,"y":0.5}'))
        self.assertEqual(sanitize_client_message(b'{"type":"key","usage":40,"phase":"down"}'),
                         {"type": "key", "usage": 40, "phase": "down"})
        self.assertIsNone(sanitize_client_message(b'{"type":"button","button":"volume"}'))
        self.assertEqual(sanitize_client_message(b'{"type":"paste","text":"hi"}'), {"type": "paste", "text": "hi"})

    def test_browser_links_are_exact_credential_free_viewer_pages(self):
        udid = "ABCDEF01-2345-6789-ABCD-EF0123456789"
        links = _browser_links({"local": "http://127.0.0.1:4280/d/" + udid,
                                "tailnet": "https://host.example.invalid:8531/d/" + udid + "?token=x"}, udid)
        self.assertEqual(links, {"local": "http://127.0.0.1:4280/d/" + udid, "tailnet": None})
        self.assertEqual(_browser_links({"local": "http://127.0.0.1:4280/watch"}, udid)["local"], None)

    def test_http_routes_relay_the_exact_simulator_stream_without_focus(self):
        build = self.register()
        preview = self.ready_preview(build["build_id"])
        service = SimpleNamespace(environ={"HERDR_HARNESS_API_TOKEN": "synthetic-main-token"},
                                  first_mate_store=self.store, simulator_previews=self.previews,
                                  first_mate=SimpleNamespace(capabilities=lambda: {}, health=lambda: {}),
                                  first_mate_changed=lambda feature_id: None)
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(service))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        origin = f"http://127.0.0.1:{server.server_port}"
        base = f"/api/v1/first-mate/features/{self.feature['id']}"

        def call(method, path, body=None, token="synthetic-main-token"):
            headers = {"Content-Type": "application/json"}
            if token:
                headers["Authorization"] = "Bearer " + token
            request = urllib.request.Request(origin + path, method=method, headers=headers,
                                             data=json.dumps(body).encode() if body is not None else None)
            try:
                with urllib.request.urlopen(request, timeout=10) as response:
                    return response.status, json.loads(response.read())
            except urllib.error.HTTPError as error:
                return error.code, json.loads(error.read())

        try:
            status, listed = call("GET", base + "/simulator-builds")
            self.assertEqual(status, 200)
            self.assertEqual(listed["builds"][0]["id"], build["build_id"])
            self.assertEqual(listed["builds"][0]["previews"][0]["id"], preview["id"])
            self.assertEqual(call("GET", base + "/simulator-builds", token=None)[0], 401)
            status, error = call("POST", base + f"/simulator-builds/{build['build_id']}/preview",
                                 {"request_id": "r", "focus": True})
            self.assertEqual((status, error["error"]["code"]), (400, "invalid_request"))
            status, error = call("GET", "/api/v1/first-mate/features/fmf_missing/simulator-builds")
            self.assertEqual(status, 404)
            status, capabilities = call("GET", "/api/v1/first-mate/capabilities")
            self.assertIn("first-mate-simulator-previews-v1", capabilities["capabilities"])
            status, machine = call("GET", "/api/v1/first-mate/simulator")
            self.assertEqual(machine["simulator"]["state"], "ready")

            client = ws.dial(origin, base + f"/simulator-previews/{preview['id']}/stream",
                             headers={"Authorization": "Bearer synthetic-main-token"}, timeout=10, max_message=1 << 22)
            opcode, payload = client.receive()
            self.assertEqual(json.loads(payload)["device"]["udid"], preview["udid"])
            client.send_text(json.dumps({"type": "hello", "codec": "h264", "focus": True, "observe": False}))
            client.send_text(json.dumps({"type": "focus"}))
            client.send_text(json.dumps({"type": "boot"}))
            client.send_text(json.dumps({"type": "touch", "phase": "began", "x": 0.25, "y": 0.5}))
            messages = [client.receive() for _ in range(3)]
            self.assertEqual(json.loads(messages[0][1])["type"], "ready")
            self.assertEqual(messages[1][0], ws.OP_BINARY)
            self.assertEqual(messages[1][1][:1], b"\x02")
            self.assertEqual(messages[2][1][:2], b"\x03\x01")
            self.assertEqual(len(messages[2][1]), 10 + 70_000)
            for _ in range(50):
                if len(self.fake.ws_messages) >= 2:
                    break
                threading.Event().wait(0.05)
            self.assertEqual(self.fake.ws_messages, [
                {"type": "hello", "codec": "h264", "observe": True, "focus": False},
                {"type": "touch", "phase": "began", "x": 0.25, "y": 0.5}])
            self.assertEqual(self.fake.ws_headers[0]["host"], self.fake.origin.removeprefix("http://"))
            self.assertEqual(self.previews.preview_detail(self.feature["id"], preview["id"])["preview"]["idle"]["watchers"], 1)
            client.close()
            client.shutdown()
            client.sock.close()
            for _ in range(50):
                if self.previews._relay_count(preview["id"]) == 0:
                    break
                threading.Event().wait(0.05)
            self.assertEqual(self.previews._relay_count(preview["id"]), 0)
            # A stream needs a real upgrade and a running preview.
            status, error = call("GET", base + f"/simulator-previews/{preview['id']}/stream")
            self.assertEqual((status, error["error"]["code"]), (426, "upgrade_required"))
            status, stopped = call("POST", base + f"/simulator-previews/{preview['id']}/stop",
                                   {"request_id": "stop-http", "mode": "shutdown"})
            self.assertEqual(status, 200)
            self.fake.finish(self.fake.portals[preview["portal_id"]]["operationId"])
            self.previews.tick()
            with self.assertRaises(ws.HandshakeRejected) as rejected:
                ws.dial(origin, base + f"/simulator-previews/{preview['id']}/stream",
                        headers={"Authorization": "Bearer synthetic-main-token"}, timeout=10, max_message=1 << 20)
            self.assertEqual(rejected.exception.status, 409)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


class SimulatorToolTests(unittest.TestCase):
    """fm_register_simulator_build is fenced like other agent writes."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.artifacts = self.root / "simportal-builds"
        self.artifacts.mkdir()
        self.fake = FakeSimPortal(self.artifacts)
        self.store = FirstMateStore(self.root / "first-mate.sqlite3")
        self.previews = SimulatorPreviews({"HERDR_SIMPORTAL_URL": self.fake.origin, "HERDR_SIMPORTAL_TOKEN": TOKEN,
                                           "HERDR_SIMPORTAL_INTAKE_ROOT": str(self.artifacts),
                                           "HERDR_STATE_DIR": str(self.root / "state")}, first_mate_store=self.store)
        self.runtime = FirstMateRuntime(self.store, environ={"PATH": "/usr/bin:/bin"}, runtime_root=self.root / "runtime",
                                        simulator_previews=self.previews)
        self.cwd = self.root / "project"
        self.cwd.mkdir()
        self.feature = self.store.create_feature({"title": "Receipts", "goal": "Synthetic", "cwd": str(self.cwd),
                                                  "request_id": "create"})

    def tearDown(self):
        self.previews.stop()
        self.fake.close()
        self.store.close()
        self.temp.cleanup()

    def worker(self):
        human = self.store.claim_message(self.feature["id"], self.runtime.owner)
        visit = self.store.start_visit(self.feature["id"], "implementation", "Implementation", "stage-sim", 1, human["id"])
        assignment = self.store.create_assignment(visit["id"], {"title": "Build receipts", "role": "implementer",
                                                                "prompt": "Build", "request_id": "assignment-sim",
                                                                "input_revision": 1})
        claim = self.store.claim_assignment(assignment["id"], self.runtime.owner)
        job = self.runtime._new_job(self.store.get_feature(self.feature["id"]), kind="worker", prompt="Build", claim=claim)
        self.runtime._bind(job, "native-sim-worker", job["session_file"])
        return job, assignment, visit

    def call(self, job, params, request_id):
        for _ in range(200):
            try:
                return self.runtime._tool(job, "fm_register_simulator_build", params, request_id)
            except DeferredOperation:
                for op in list(self.fake.operations.values()):
                    if op["status"] not in TERMINAL:
                        self.fake.finish(op["id"])
                threading.Event().wait(0.05)
        self.fail("registration never settled")

    def test_worker_registration_records_its_own_identity(self):
        job, assignment, visit = self.worker()
        self.assertTrue(job["simulator_previews"])
        self.assertIn("fm_register_simulator_build", _pi_command(job)[_pi_command(job).index("--append-system-prompt") + 1])
        app = make_app(self.cwd / "DerivedData/Build/Products/Debug-iphonesimulator")
        result = self.call(job, {"app_path": str(app), "label": "Round 1"}, "spool-worker")
        self.assertEqual(result["status"], "ready")
        [body] = self.fake.mutations("/api/builds")
        self.assertEqual(body["scope"]["checkpointId"], assignment["id"])
        self.assertEqual(body["scope"]["sessionId"], "native-sim-worker")
        build = self.previews.feature_builds(self.feature["id"])["builds"][0]
        self.assertEqual((build["visit_id"], build["assignment_id"], build["native_session_id"]),
                         (visit["id"], assignment["id"], "native-sim-worker"))
        self.assertEqual(build["stage_title"], "Implementation")

    def test_stale_or_foreign_roles_cannot_register(self):
        job, _, _ = self.worker()
        app = make_app(self.cwd / "build/Debug-iphonesimulator")
        forged = {**job, "claim": {**job["claim"], "generation": job["claim"]["generation"] + 1}}
        with self.assertRaisesRegex(FirstMateError, "active assignment scope"):
            self.runtime._tool(forged, "fm_register_simulator_build", {"app_path": str(app)}, "spool-forged")
        advisor = {"feature_id": self.feature["id"], "kind": "advisor", "claim": {}}
        with self.assertRaisesRegex(ValueError, "role and assignment scope"):
            self.runtime._tool(advisor, "fm_register_simulator_build", {"app_path": str(app)}, "spool-advisor")
        stale = {"feature_id": self.feature["id"], "kind": "coordinator", "claim": {}, "owner": "runtime_other"}
        with self.assertRaisesRegex(FirstMateError, "ownership changed"):
            self.runtime._tool(stale, "fm_register_simulator_build", {"app_path": str(app)}, "spool-stale")
        self.assertEqual(self.fake.mutations("/api/builds"), [])

    def test_unconfigured_machines_hide_the_tool(self):
        runtime = FirstMateRuntime(self.store, environ={"PATH": "/usr/bin:/bin"}, runtime_root=self.root / "runtime-2",
                                   simulator_previews=SimulatorPreviews({"HERDR_STATE_DIR": str(self.root / "none")}))
        human = self.store.claim_message(self.feature["id"], runtime.owner)
        job = runtime._new_job(self.store.get_feature(self.feature["id"]), kind="coordinator", prompt="x", claim=human)
        self.assertNotIn("simulator_previews", job)
        self.assertNotIn("fm_register_simulator_build", _pi_command(job)[_pi_command(job).index("--system-prompt") + 1])
        with self.assertRaises(FirstMateError) as caught:
            runtime._tool({**job, "owner": runtime.owner}, "fm_register_simulator_build", {"app_path": "/tmp/X.app"}, "spool-off")
        self.assertEqual(caught.exception.code, "simulator_unconfigured")


if __name__ == "__main__":
    unittest.main()

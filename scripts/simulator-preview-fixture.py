#!/usr/bin/env python3
"""Local fixture for the Mac simulator stream: a fake SimPortal behind the real companion relay.

Everything is synthetic: an in-process SimPortal fake (tests/test_simulator_previews.py),
a throwaway app bundle, and temporary stores. No simulator, Xcode build, SimPortal,
operator configuration, or credential is used. It registers one checkpoint, starts
one preview, prints the connection details as one JSON line, and serves until it is
interrupted. On exit it writes the viewer messages the fake received to --report.

    python3.11 scripts/simulator-preview-fixture.py --port 9197 --report /tmp/viewer.json
"""
from __future__ import annotations

import argparse
import json
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import zlib
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

from herdr_harness.first_mate_store import FirstMateStore  # noqa: E402
from herdr_harness.server import make_handler  # noqa: E402
from herdr_harness.simulator_previews import CheckpointContext, SimulatorPreviews  # noqa: E402
from tests.test_simulator_previews import TOKEN, FakeSimPortal, make_app  # noqa: E402

API_TOKEN = "synthetic-fixture-token"


def jpeg(root: Path, color: tuple[int, int, int] = (110, 90, 200)) -> bytes | None:
    """A small solid-color JPEG made with the system's sips (macOS)."""
    width, height = 40, 80
    rows = b"".join(b"\x00" + bytes(color) * width for _ in range(height))
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!IIBBBBB", width, height, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
    (root / "frame.png").write_bytes(png)
    try:
        subprocess.run(["sips", "-s", "format", "jpeg", str(root / "frame.png"), "--out", str(root / "frame.jpg")],
                       check=True, capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return (root / "frame.jpg").read_bytes()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    temp = tempfile.TemporaryDirectory(prefix="herdr-simulator-fixture-")
    root = Path(temp.name).resolve()
    artifacts = root / "simportal-builds"
    artifacts.mkdir()
    fake = FakeSimPortal(artifacts)
    fake.jpeg_frame = jpeg(root)
    fake.input_jpeg_frame = jpeg(root, (40, 170, 100))
    fake.force_jpeg = True
    store = FirstMateStore(root / "first-mate.sqlite3")
    workspace = root / "project"
    workspace.mkdir()
    feature = store.create_feature({"title": "Receipt export", "goal": "Synthetic receipts", "cwd": str(workspace),
                                    "request_id": "fixture"})
    previews = SimulatorPreviews({"HERDR_SIMPORTAL_URL": fake.origin, "HERDR_SIMPORTAL_TOKEN": TOKEN,
                                  "HERDR_SIMPORTAL_INTAKE_ROOT": str(artifacts), "HERDR_STATE_DIR": str(root / "state")},
                                 first_mate_store=store)
    context = CheckpointContext(feature_id=feature["id"], feature_title="Receipt export", visit_id=None,
                                visit_title=None, assignment_id=None, assignment_title="Fixture build",
                                native_session_id="fixture-session", workspace=str(workspace), role="worker")
    app = make_app(workspace / "build/Build/Products/Debug-iphonesimulator", "Receipts")
    settle = threading.Event()

    def worker() -> None:
        # Stands in for SimPortal's worker: every accepted operation succeeds.
        while not settle.wait(0.2):
            with fake.lock:
                pending = [op["id"] for op in fake.operations.values() if op["status"] in {"queued", "running"}]
            for operation_id in pending:
                fake.finish(operation_id)

    threading.Thread(target=worker, daemon=True).start()
    future = previews.submit_registration("fixture-spool", context, {"app_path": str(app), "label": "Round 1: fixture"})
    build = future.result(timeout=60)
    opened = previews.open_preview(feature["id"], build["build_id"], request_id="fixture-open")["preview"]
    for _ in range(50):
        if previews.preview_detail(feature["id"], opened["id"])["preview"]["phase"] == "running":
            break
        threading.Event().wait(0.2)
    service = SimpleNamespace(environ={"HERDR_HARNESS_API_TOKEN": API_TOKEN}, first_mate_store=store,
                              simulator_previews=previews,
                              first_mate=SimpleNamespace(capabilities=lambda: {}, health=lambda: {}),
                              first_mate_changed=lambda feature_id: None)
    class FixtureHandler(make_handler(service)):
        def do_GET(self):
            if self.path != "/fixture/viewer-messages":
                return super().do_GET()
            if self.headers.get("Authorization") != "Bearer " + API_TOKEN:
                self.send_error(401)
                return
            with fake.lock:
                payload = json.dumps({"messages": fake.ws_messages}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    server = ThreadingHTTPServer(("127.0.0.1", args.port), FixtureHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(json.dumps({"base_url": f"http://127.0.0.1:{server.server_port}", "token": API_TOKEN,
                      "feature_id": feature["id"], "build_id": build["build_id"], "preview_id": opened["id"],
                      "jpeg": fake.jpeg_frame is not None}), flush=True)
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    stop.wait()
    settle.set()
    if args.report:
        args.report.write_text(json.dumps({"viewer_messages": fake.ws_messages, "viewer_headers": fake.ws_headers}, indent=1))
    server.shutdown()
    previews.stop()
    fake.close()
    store.close()
    temp.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

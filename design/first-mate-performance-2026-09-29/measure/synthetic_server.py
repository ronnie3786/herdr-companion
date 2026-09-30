#!/usr/bin/env python3
"""Local-only verification-read benchmark. Never opens an operator database.

Run from the checkout with Python 3.11+. Uses the existing verification test
fixture, a temporary Git repository, and synthetic events. Reports runtime
method and JSON encoding time, not HTTP/network latency or production timings.
"""
from __future__ import annotations

import json
from pathlib import Path
import statistics
import sys
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT), str(ROOT / "tests")]
from test_first_mate_verification_runtime import SUITES, VerificationRuntimeTests


def main() -> None:
    fixture = VerificationRuntimeTests()
    fixture.setUp()
    try:
        assignment = fixture.stage_and_assignment()
        for index in range(49):
            fixture.store.create_assignment(assignment["visit_id"], {
                "title": f"Synthetic assignment {index}", "role": "tester",
                "prompt": "Inspect synthetic data.", "request_id": f"synthetic-{index}",
                "metadata": assignment["metadata"],
            })
        fixture.record_inventory(SUITES, revision=fixture.base)
        fixture.record_run("synthetic-verification", SUITES, revision=fixture.base)
        payload = {"text": "Synthetic telemetry content. " * 40}
        with fixture.store._transaction():
            for index in range(22000):
                kind = "pi.synthetic" if index < 20000 else "synthetic.journal"
                fixture.store._event(fixture.feature["id"], kind, "Synthetic event", payload)
        feature_id = fixture.feature["id"]
        for name, request in [
            ("list", fixture.runtime.list_features),
            ("journal-snapshot", lambda: fixture.runtime.snapshot(feature_id, events="journal")),
            ("board", lambda: fixture.runtime.board(feature_id, messages=60, journal=0)),
        ]:
            timings, sizes, full_reads = [], [], []
            for _ in range(5):
                with patch.object(fixture.store, "snapshot", wraps=fixture.store.snapshot) as reads:
                    start = time.perf_counter()
                    result = request()
                    encoded = json.dumps(result).encode()
                    timings.append((time.perf_counter() - start) * 1000)
                    sizes.append(len(encoded))
                    full_reads.append(sum(call.kwargs.get("events", "all") == "all" for call in reads.call_args_list))
            print(json.dumps({"request": name, "median_ms": round(statistics.median(timings), 2),
                              "max_ms": round(max(timings), 2), "bytes": max(sizes),
                              "full_snapshot_reads_per_request": max(full_reads)}), flush=True)
    finally:
        fixture.tearDown()


if __name__ == "__main__":
    main()

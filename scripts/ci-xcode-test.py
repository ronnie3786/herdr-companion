#!/usr/bin/env python3
"""Run one Xcode unit-test target, then retry only the tests that failed.

`xcodebuild -retry-tests-on-failure -test-iterations N` repeats the whole Swift
Testing run when any test fails, so one flaky test cost a second or third full
pass of every suite. Here the first pass runs once. If it fails, the failed
test cases are read from its result bundle and rerun alone against the
already-built products. The job still fails when they fail again, when more
than MAX_RETRIED tests failed (a real break, not a flake), or when a failure
cannot be tied to a test case (a build error or a crashed bundle).

Usage: ci-xcode-test.py --result-dir DIR -- <xcodebuild arguments without an action>
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

MAX_RETRIED = 10
RETRY_ITERATIONS = 2


def failed_tests(results: dict) -> tuple[list[str], bool]:
    """Failed test cases as `<bundle>/<identifier>`, and whether every failure is one.

    A failed suite or bundle with no failed test case below it (a crash or a
    failure outside any test) makes the result incomplete, so it is never retried.
    """
    failed: list[str] = []
    complete = True

    def walk(node: dict, bundle: str | None) -> bool:
        nonlocal complete
        kind = node.get("nodeType")
        if kind == "Unit test bundle":
            bundle = node.get("name")
        if kind == "Test Case":
            if node.get("result") != "Failed":
                return False
            identifier = node.get("nodeIdentifier")
            if bundle and identifier:
                failed.append(f"{bundle}/{identifier}")
            else:
                complete = False
            return True
        below = [walk(child, bundle) for child in node.get("children") or []]
        if node.get("result") == "Failed" and not any(below):
            complete = False
        return any(below)

    for node in results.get("testNodes") or []:
        walk(node, None)
    return sorted(set(failed)), complete


def xcodebuild(arguments: list[str]) -> int:
    print("+ xcodebuild " + " ".join(arguments), flush=True)
    return subprocess.run(["xcodebuild", *arguments]).returncode


def read_results(bundle: Path) -> dict | None:
    if not bundle.exists():
        return None
    process = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)],
                             capture_output=True, text=True)
    if process.returncode:
        return None
    try:
        return json.loads(process.stdout)
    except ValueError:
        return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--result-dir", type=Path, required=True)
    parser.add_argument("xcodebuild", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    base = [value for value in args.xcodebuild if value != "--"]
    targets = [value for value in base if value.startswith("-only-testing:")]
    if len(targets) != 1:
        parser.error("pass exactly one -only-testing:<target>")
    common = [value for value in base if value not in targets]
    args.result_dir.mkdir(parents=True, exist_ok=True)

    first = args.result_dir / "first.xcresult"
    status = xcodebuild([*common, "test", *targets, "-resultBundlePath", str(first)])
    if status == 0:
        return 0
    results = read_results(first)
    if results is None:
        print("No test results to retry from (a build or launch failure).", flush=True)
        return status
    failed, complete = failed_tests(results)
    if not failed or not complete:
        print("A failure could not be tied to a test case, so nothing is retried.", flush=True)
        return status
    if len(failed) > MAX_RETRIED:
        print(f"{len(failed)} tests failed; that is a break, not a flake, so nothing is retried.", flush=True)
        return status
    print("Retrying only the failed tests:\n  " + "\n  ".join(failed), flush=True)
    retry = args.result_dir / "retry.xcresult"
    status = xcodebuild([*common, "test-without-building", *[f"-only-testing:{name}" for name in failed],
                         "-resultBundlePath", str(retry), "-retry-tests-on-failure",
                         "-test-iterations", str(RETRY_ITERATIONS)])
    if status == 0:
        # A visible annotation keeps flaky tests from going unnoticed.
        print("::warning title=Flaky tests::Passed only on retry: " + ", ".join(failed), flush=True)
    return status


if __name__ == "__main__":
    sys.exit(main())

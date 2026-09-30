#!/usr/bin/env python3
"""Run the Mac (and, when needed, iOS) tests for one pushed commit on this Mac,
then post the result to GitHub as the "Mac tests (local)" commit status.

Verify on GitHub no longer runs these suites; land-pr.py, release-macos.py
publish and the Code Factory require this status instead. The commit is tested
in a clean checkout of exactly that revision (untracked or uncommitted files in
your working copy never count), kept at a fixed path with its own derived data
so consecutive runs build incrementally. One run at a time: a second run waits.

No new run is needed, and success is posted straight away, when the same code
already passed (see scripts/verification_policy.py). --force always tests.

Usage: local-verify.py [REV] [--ios auto|always|never] [--force] [--no-post]

The last line of output is a JSON summary. The status description is public:
it never contains paths or machine names.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
from typing import Callable, Iterator

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verification_policy as policy  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "ronnie3786/herdr-companion"
CACHE = Path(os.environ.get("HERDR_LOCAL_VERIFY_CACHE") or Path.home() / "Library/Caches/herdr-companion/local-verify")
STEP_TIMEOUT_SECONDS = 45 * 60
KEEP_RESULTS = 5
EXCERPT = re.compile(r"✘|error:|\*\* TEST FAILED|\*\* BUILD FAILED|Test Case .* failed|FAIL:|Traceback|AssertionError")
XCODE_COMMON = ["CODE_SIGNING_ALLOWED=NO", "COMPILER_INDEX_STORE_ENABLE=NO"]


class VerifyError(RuntimeError):
    pass


def command(arguments: list[str], *, cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess:
    process = subprocess.run(arguments, cwd=cwd, capture_output=True, text=True)
    if check and process.returncode:
        raise VerifyError(f"{' '.join(arguments[:3])} failed: {(process.stderr or process.stdout).strip()[:400]}")
    return process


def repo_git(*arguments: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(ROOT), *arguments], capture_output=True, text=True)


class GitHub:
    """The few GitHub calls this script needs, through the operator's `gh` login."""

    def __init__(self, run: Callable[[list[str]], subprocess.CompletedProcess] = command):
        self._run = run

    def _api(self, endpoint: str, *fields: str, method: str = "GET"):
        arguments = ["gh", "api", f"repos/{REPOSITORY}/{endpoint}", "--method", method]
        for field in fields:
            arguments += ["-f", field]
        output = self._run(arguments).stdout
        return json.loads(output) if output.strip() else None

    def state(self, sha: str) -> str:
        """This context's latest state for the commit, or "none"."""
        for status in (self._api(f"commits/{sha}/status") or {}).get("statuses") or []:
            if status.get("context") == policy.LOCAL_CONTEXT:
                return str(status.get("state") or "none")
        return "none"

    def post(self, sha: str, state: str, description: str) -> None:
        self._api(f"statuses/{sha}", f"state={state}", f"context={policy.LOCAL_CONTEXT}",
                  f"description={description[:140]}", method="POST")

    def pull_heads(self, sha: str) -> list[str]:
        return [pr["head"]["sha"] for pr in self._api(f"commits/{sha}/pulls") or []
                if pr.get("merge_commit_sha") == sha and pr.get("merged_at") and (pr.get("head") or {}).get("sha")]

    def tree(self, sha: str) -> str | None:
        return ((self._api(f"git/commits/{sha}") or {}).get("tree") or {}).get("sha")


@contextmanager
def exclusive(path: Path) -> Iterator[None]:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Another local verification is running; waiting for it to finish.", flush=True)
            fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def ios_required(sha: str, mode: str, run_git: policy.Git | None = None) -> bool:
    """iOS tests run when anything the iOS app builds from changed on this branch."""
    if mode != "auto":
        return mode == "always"
    run_git = run_git or repo_git
    if run_git("merge-base", "--is-ancestor", sha, "origin/main").returncode == 0:
        changed = run_git("diff", "--name-only", f"{sha}^1", sha)
    else:
        changed = run_git("diff", "--name-only", f"origin/main...{sha}")
    return changed.returncode != 0 or any(policy.IOS_PATHS.match(path) for path in changed.stdout.splitlines())


def checkout(sha: str) -> Path:
    """A clean checkout of exactly `sha` at a fixed path, so builds stay incremental."""
    source = CACHE / "source"
    if not (source / ".git").exists():
        shutil.rmtree(source, ignore_errors=True)
        command(["git", "init", "--quiet", str(source)])
    command(["git", "-C", str(source), "fetch", "--quiet", "--no-tags", str(ROOT), sha])
    command(["git", "-C", str(source), "checkout", "--quiet", "--force", "--detach", sha])
    command(["git", "-C", str(source), "clean", "-ffdxq"])
    return source


def run_step(name: str, arguments: list[str], cwd: Path, log: Path) -> bool:
    started = time.monotonic()
    print(f"{name}: running", flush=True)
    with log.open("a") as output:
        output.write(f"\n=== {name}: {' '.join(arguments)}\n")
        output.flush()
        process = subprocess.Popen(arguments, cwd=cwd, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=STEP_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            output.write(f"\n=== {name}: stopped after {STEP_TIMEOUT_SECONDS // 60} minutes\n")
            code = -1
        except BaseException:
            os.killpg(process.pid, signal.SIGKILL)
            raise
    print(f"{name}: {'passed' if code == 0 else 'FAILED'} in {duration(time.monotonic() - started)}", flush=True)
    return code == 0


def duration(seconds: float) -> str:
    minutes, seconds = divmod(int(seconds), 60)
    return f"{minutes}m {seconds:02d}s" if minutes else f"{seconds}s"


def ios_destination() -> str:
    devices = json.loads(command(["xcrun", "simctl", "list", "devices", "available", "--json"]).stdout)["devices"]
    for runtime, entries in sorted(devices.items(), reverse=True):
        if "iOS" in runtime:
            for device in entries:
                if "iPhone" in device.get("name", ""):
                    return f"platform=iOS Simulator,id={device['udid']}"
    raise VerifyError("No available iPhone simulator for the iOS tests")


def excerpt(log: Path, source: Path) -> str:
    """Failure lines for a reviser, with local paths replaced."""
    lines = log.read_text(errors="replace").splitlines()
    picked = [line for line in lines if EXCERPT.search(line)][-60:] + ["--- last lines ---", *lines[-20:]]
    text = "\n".join(picked)
    return text.replace(str(source), "<checkout>").replace(str(Path.home()), "~")


def prune(directory: Path, keep: int) -> None:
    entries = sorted(directory.glob("*"), key=lambda path: path.stat().st_mtime, reverse=True) if directory.exists() else []
    for old in entries[keep:]:
        shutil.rmtree(old, ignore_errors=True) if old.is_dir() else old.unlink(missing_ok=True)


def test(sha: str, ios: bool) -> tuple[bool, str, dict]:
    source = checkout(sha)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    results = CACHE / "results" / f"{sha[:12]}-{stamp}"
    log = CACHE / "logs" / f"{sha[:12]}-{stamp}.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    python = sys.executable
    started = time.monotonic()
    ok = run_step("Mac script tests", [python, "-m", "unittest", "discover", "-s", "herdr-harness-mac/Scripts", "-p", "test_*.py"],
                  source, log)
    ok = run_step("Mac unit tests", [
        python, "scripts/ci-xcode-test.py", "--result-dir", str(results / "mac"), "--",
        "-project", "herdr-harness-mac/herdr-harness-mac.xcodeproj", "-scheme", "herdr-harness-mac",
        "-destination", "platform=macOS", "-derivedDataPath", str(CACHE / "mac-derived"), *XCODE_COMMON,
        "-only-testing:herdr-harness-macTests"], source, log) and ok
    if ios:
        ok = run_step("iOS unit tests", [
            python, "scripts/ci-xcode-test.py", "--result-dir", str(results / "ios"), "--",
            "-project", "herdr-harness-ios/herdr-harness-ios.xcodeproj", "-scheme", "herdr-harness-ios",
            "-destination", ios_destination(), "-derivedDataPath", str(CACHE / "ios-derived"), *XCODE_COMMON,
            "-only-testing:herdr-harness-iosTests", "-parallel-testing-enabled", "NO"], source, log) and ok
    prune(CACHE / "results", KEEP_RESULTS)
    prune(CACHE / "logs", 20)
    scope = "Mac and iOS tests" if ios else "Mac tests (iOS unchanged)"
    description = f"{scope} {'passed' if ok else 'failed'} in {duration(time.monotonic() - started)}"
    return ok, description, {"log": str(log), "excerpt": "" if ok else excerpt(log, source)}


def verify(sha: str, *, ios_mode: str = "auto", force: bool = False, post: bool = True,
           github: GitHub | None = None) -> dict:
    github = github or GitHub()
    repo_git("fetch", "--quiet", "origin")
    if post:
        try:
            github.state(sha)
        except VerifyError:
            raise VerifyError("Could not read this commit on GitHub: push it first, "
                              "or pass --no-post to test without posting") from None
    with exclusive(CACHE / "lock"):
        if post and not force:
            reused = policy.reusable_result(sha, passed=lambda value: github.state(value) == "success",
                                            pull_heads=github.pull_heads, head_tree=github.tree, run_git=repo_git)
            if reused:
                if github.state(sha) != "success":
                    github.post(sha, "success", f"Reused: {reused}")
                return {"ok": True, "sha": sha, "state": "success", "reused": reused}
        if post:
            github.post(sha, "pending", "Running on a Mac")
        try:
            ok, description, details = test(sha, ios_required(sha, ios_mode))
        except BaseException as error:
            if post:
                github.post(sha, "error", "Stopped before finishing" if isinstance(error, (KeyboardInterrupt, SystemExit))
                            else "Could not run the tests")
            raise
        if post:
            github.post(sha, "success" if ok else "failure", description)
        return {"ok": ok, "sha": sha, "state": "success" if ok else "failure", "description": description, **details}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("revision", nargs="?", default="HEAD")
    parser.add_argument("--ios", choices=("auto", "always", "never"), default="auto")
    parser.add_argument("--force", action="store_true", help="Test even when the same code already passed")
    parser.add_argument("--no-post", action="store_true", help="Test without posting a GitHub status")
    args = parser.parse_args(argv)
    # A terminated run (a Code Factory timeout) still reports instead of staying pending.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        sha = command(["git", "-C", str(ROOT), "rev-parse", "--verify", f"{args.revision}^{{commit}}"]).stdout.strip()
        result = verify(sha, ios_mode=args.ios, force=args.force or args.no_post, post=not args.no_post)
    except VerifyError as error:
        result = {"ok": False, "error": str(error)}
    print(json.dumps(result))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())

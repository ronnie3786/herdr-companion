#!/usr/bin/env python3
"""Decide what one Verify run must do, and write it to $GITHUB_OUTPUT.

Mac and iOS tests are not run here: scripts/local-verify.py runs them on a Mac
and posts a commit status that landing and publication require.

`privacy` is false only when this exact commit was already scanned:
- a pull request from a branch of this repository: the push run for the same
  commit checks exactly that commit;
- a push of a commit that already has a successful push run (a branch landed on
  the default branch by fast-forward). Only push runs count, because they check
  the exact commit; a pull request run checks a merge preview instead.

`tests` is false in those cases, and also when tested code is reused (see
scripts/verification_policy.py): a squash merge whose tree equals a pull request
head that passed, or a docs, release-notes or version-only commit whose parent
passed. A parent whose push run is still going is waited for, up to
PARENT_WAIT_SECONDS, because a release bump is pushed right after its merge.
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.request
from pathlib import Path
from typing import Callable, Mapping

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verification_policy as policy  # noqa: E402

PARENT_WAIT_SECONDS = 20 * 60
POLL_SECONDS = 20


def push_runs(env: Mapping[str, str], fetch: Callable[[str], dict], sha: str) -> list[dict]:
    url = (f"{env['GITHUB_API_URL']}/repos/{env['GITHUB_REPOSITORY']}/actions/workflows/{env['WORKFLOW_FILE']}"
           f"/runs?head_sha={sha}&event=push&per_page=20")
    return [run for run in fetch(url).get("workflow_runs") or []
            if str(run.get("id")) != env["GITHUB_RUN_ID"] and run.get("head_sha") == sha and run.get("event") == "push"]


def verified_by_push_run(env: Mapping[str, str], fetch: Callable[[str], dict], sha: str | None = None) -> str | None:
    """The URL of an earlier successful push run of this workflow for this exact commit."""
    for run in push_runs(env, fetch, sha or env["GITHUB_SHA"]):
        if run.get("conclusion") == "success":
            return run.get("html_url") or str(run.get("id"))
    return None


def passed_in_ci(env: Mapping[str, str], fetch: Callable[[str], dict], *, sleep: Callable[[float], None] = time.sleep,
                 clock: Callable[[], float] = time.monotonic) -> Callable[[str], bool]:
    """Whether a commit has a successful push run, waiting for one still in progress."""
    def passed(sha: str) -> bool:
        deadline = clock() + PARENT_WAIT_SECONDS
        while True:
            runs = push_runs(env, fetch, sha)
            if any(run.get("conclusion") == "success" for run in runs):
                return True
            if not any(run.get("status") != "completed" for run in runs) or clock() >= deadline:
                return False
            sleep(POLL_SECONDS)
    return passed


def github_fetch(token: str) -> Callable[[str], dict]:
    def fetch(url: str) -> dict:
        request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}",
                                                       "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read())
    return fetch


def merged_pull_heads(env: Mapping[str, str], fetch: Callable[[str], dict]) -> Callable[[str], list[str]]:
    def heads(sha: str) -> list[str]:
        payload = fetch(f"{env['GITHUB_API_URL']}/repos/{env['GITHUB_REPOSITORY']}/commits/{sha}/pulls")
        return [pr["head"]["sha"] for pr in payload if isinstance(pr, dict)
                and pr.get("merge_commit_sha") == sha and pr.get("merged_at") and (pr.get("head") or {}).get("sha")]
    return heads


def remote_tree(env: Mapping[str, str], fetch: Callable[[str], dict]) -> Callable[[str], str | None]:
    def tree(sha: str) -> str | None:
        return (fetch(f"{env['GITHUB_API_URL']}/repos/{env['GITHUB_REPOSITORY']}/git/commits/{sha}").get("tree") or {}).get("sha")
    return tree


def plan(env: Mapping[str, str], *, fetch: Callable[[str], dict], run_git: policy.Git = policy.git,
         sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic) -> dict:
    if env["GITHUB_EVENT_NAME"] == "pull_request" and env.get("HEAD_REPOSITORY") == env["GITHUB_REPOSITORY"]:
        return {"tests": False, "privacy": False,
                "reason": "The push run for this commit checks it; a same-repository pull request run would repeat it."}
    if env["GITHUB_EVENT_NAME"] != "push":
        return {"tests": True, "privacy": True, "reason": "Check this pull request in full."}
    earlier = verified_by_push_run(env, fetch)
    if earlier:
        return {"tests": False, "privacy": False, "reason": f"This exact commit already passed Verify: {earlier}"}
    try:
        reused = policy.reusable_result(env["GITHUB_SHA"], passed=passed_in_ci(env, fetch, sleep=sleep, clock=clock),
                                        pull_heads=merged_pull_heads(env, fetch), head_tree=remote_tree(env, fetch),
                                        run_git=run_git)
    except Exception as error:  # noqa: BLE001 - any doubt means the tests run
        reused = None
        print(f"Could not check for reusable results ({type(error).__name__}); running the tests.")
    if reused:
        return {"tests": False, "privacy": True, "reason": f"Tests reused: {reused}. The privacy scan still runs."}
    return {"tests": True, "privacy": True, "reason": "Check this commit in full."}


def main() -> int:
    env = dict(os.environ)
    result = plan(env, fetch=github_fetch(env["GH_TOKEN"]))
    print(result["reason"])
    with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"tests={'true' if result['tests'] else 'false'}\n")
        output.write(f"privacy={'true' if result['privacy'] else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

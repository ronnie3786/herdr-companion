#!/usr/bin/env python3
"""Decide what one Verify run must do, and write it to $GITHUB_OUTPUT.

`run` is false when this commit is already verified elsewhere, so no test
job repeats the work:
- a pull request from a branch of this repository: the push run for the same
  commit tests exactly that commit;
- a push of a commit that already has a successful push run (a branch landed on
  the default branch by fast-forward). Only push runs count, because they test
  the exact commit; a pull request run tests a merge preview instead.

`ios` is false when nothing the iOS app builds from changed. A branch push
compares the whole branch with the default branch, so an earlier push's iOS
change stays covered.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.request
from typing import Callable, Mapping

IOS_PATHS = re.compile(r"^(herdr-harness-ios/|HerdrFirstMateShared/|HerdrFirstMateSharedTests/|\.github/workflows/verify\.yml$)")
ZERO = "0" * 40


def git(*arguments: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *arguments], capture_output=True, text=True)


def verified_by_push_run(env: Mapping[str, str], fetch: Callable[[str], dict]) -> str | None:
    """The URL of an earlier successful push run of this workflow for this exact commit."""
    url = (f"{env['GITHUB_API_URL']}/repos/{env['GITHUB_REPOSITORY']}/actions/workflows/{env['WORKFLOW_FILE']}"
           f"/runs?head_sha={env['GITHUB_SHA']}&event=push&status=success&per_page=20")
    for run in fetch(url).get("workflow_runs") or []:
        if (str(run.get("id")) != env["GITHUB_RUN_ID"] and run.get("head_sha") == env["GITHUB_SHA"]
                and run.get("event") == "push" and run.get("conclusion") == "success"):
            return run.get("html_url") or str(run.get("id"))
    return None


def github_fetch(token: str) -> Callable[[str], dict]:
    def fetch(url: str) -> dict:
        request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}",
                                                       "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read())
    return fetch


def change_range(env: Mapping[str, str], run_git: Callable[..., subprocess.CompletedProcess]) -> str | None:
    """The commits whose files decide the iOS job, or None for a full run."""
    event, default = env["GITHUB_EVENT_NAME"], env["DEFAULT_BRANCH"]
    if event == "pull_request":
        run_git("fetch", "--quiet", "origin", env["BASE_REF"])
        return f"origin/{env['BASE_REF']}...HEAD"
    if event == "push" and env["GITHUB_REF_NAME"] != default:
        run_git("fetch", "--quiet", "origin", default)
        return f"origin/{default}...HEAD"
    before = env.get("BEFORE") or ""
    if before and before != ZERO and run_git("cat-file", "-e", before + "^{commit}").returncode == 0:
        return f"{before}..HEAD"
    return None


def plan(env: Mapping[str, str], *, fetch: Callable[[str], dict],
         run_git: Callable[..., subprocess.CompletedProcess] = git) -> dict:
    if env["GITHUB_EVENT_NAME"] == "pull_request" and env.get("HEAD_REPOSITORY") == env["GITHUB_REPOSITORY"]:
        return {"run": False, "ios": False,
                "reason": "The push run for this commit verifies it; a same-repository pull request run would repeat it."}
    if env["GITHUB_EVENT_NAME"] == "push":
        earlier = verified_by_push_run(env, fetch)
        if earlier:
            return {"run": False, "ios": False, "reason": f"This exact commit already passed Verify: {earlier}"}
    commits = change_range(env, run_git)
    ios = True
    if commits:
        changed = run_git("diff", "--name-only", commits)
        ios = changed.returncode != 0 or any(IOS_PATHS.match(path) for path in changed.stdout.splitlines())
    return {"run": True, "ios": ios, "reason": f"Verify this commit (iOS {'required' if ios else 'unchanged'}; "
                                                f"range: {commits or 'full run'})."}


def main() -> int:
    env = dict(os.environ)
    result = plan(env, fetch=github_fetch(env["GH_TOKEN"]))
    print(result["reason"])
    with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"run={'true' if result['run'] else 'false'}\n")
        output.write(f"ios={'true' if result['ios'] else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

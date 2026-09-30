#!/usr/bin/env python3
"""Land a verified pull request by fast-forwarding the default branch to its head.

A merge commit is a new revision, so every release had to wait for Verify to
test the same code again. Fast-forwarding instead makes the default branch
point at the exact commit that already passed, and Verify's plan job skips a
commit with a successful push run, so a release can be prepared right away.

The pull request must be open, not a draft, from this repository, targeting the
default branch, already contain the default branch (update it first if not),
and have a successful latest push run of Verify and a successful "Mac tests
(local)" status (scripts/local-verify.py) for its head commit. GitHub marks the
pull request merged once its head is on the default branch.

Usage: land-pr.py <number> [--delete-branch]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from typing import Callable

REPOSITORY = "ronnie3786/herdr-companion"
WORKFLOW = "Verify"
LOCAL_CONTEXT = "Mac tests (local)"  # posted by scripts/local-verify.py


class LandError(RuntimeError):
    pass


def command(arguments: list[str]) -> str:
    process = subprocess.run(arguments, capture_output=True, text=True)
    if process.returncode:
        raise LandError(f"{' '.join(arguments[:3])} failed: {(process.stderr or process.stdout).strip()[:500]}")
    return process.stdout


def land(number: int, *, delete_branch: bool = False, run: Callable[[list[str]], str] = command,
         sleep: Callable[[float], None] = time.sleep) -> dict:
    pr = json.loads(run(["gh", "pr", "view", str(number), "--repo", REPOSITORY, "--json",
                         "state,isDraft,baseRefName,headRefName,headRefOid,isCrossRepository,url"]))
    default = run(["gh", "repo", "view", REPOSITORY, "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"]).strip()
    if pr["state"] != "OPEN" or pr["isDraft"]:
        raise LandError("Only an open, ready pull request can land")
    if pr["isCrossRepository"] or pr["baseRefName"] != default:
        raise LandError(f"Only a branch of this repository targeting {default} can land by fast-forward")
    head = pr["headRefOid"]
    run(["git", "fetch", "--quiet", "origin", default, pr["headRefName"]])
    if run(["git", "rev-parse", f"origin/{pr['headRefName']}"]).strip() != head:
        raise LandError("The fetched branch does not match the pull request head; retry")
    try:
        run(["git", "merge-base", "--is-ancestor", f"origin/{default}", head])
    except LandError:
        raise LandError(f"The branch is behind {default}. Merge origin/{default} into it, push, "
                        "and land after Verify passes on the new head.") from None
    runs = json.loads(run(["gh", "run", "list", "--repo", REPOSITORY, "--commit", head, "--workflow", WORKFLOW,
                           "--event", "push", "--json", "headSha,status,conclusion,url", "--limit", "20"]))
    if not runs or runs[0]["headSha"] != head or runs[0]["status"] != "completed" or runs[0]["conclusion"] != "success":
        raise LandError("The latest push run of Verify for the pull request head must have passed")
    statuses = json.loads(run(["gh", "api", f"repos/{REPOSITORY}/commits/{head}/status"])).get("statuses") or []
    if not any(item.get("context") == LOCAL_CONTEXT and item.get("state") == "success" for item in statuses):
        raise LandError(f"The Mac tests must have passed for the pull request head: run scripts/local-verify.py {head[:12]}")
    # A plain push only fast-forwards; the remote rejects anything else.
    run(["git", "push", "--quiet", "origin", f"{head}:refs/heads/{default}"])
    state = ""
    for _ in range(20):
        state = json.loads(run(["gh", "pr", "view", str(number), "--repo", REPOSITORY, "--json", "state"]))["state"]
        if state == "MERGED":
            break
        sleep(3)
    if delete_branch and state == "MERGED":
        run(["git", "push", "--quiet", "origin", "--delete", pr["headRefName"]])
    return {"ok": True, "landed": head, "branch": default, "pullRequest": pr["url"], "state": state,
            "verified": runs[0]["url"]}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("number", type=int)
    parser.add_argument("--delete-branch", action="store_true")
    args = parser.parse_args(argv)
    try:
        print(json.dumps(land(args.number, delete_branch=args.delete_branch)))
    except LandError as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

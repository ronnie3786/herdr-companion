# First Mate archive cleanup brief

Product brief from Ronnie's discussion, October 3, 2026. This captures the request and discussion for a new build session. It is not an implementation plan, and the proposed behavior has not been built in this session.

**What I asked**

When I archive a First Mate session after it is marked complete, does that clean up its resources, including app builds, worktrees, documents, artifacts, and branches?

The current behavior we inspected only removes the session from the active list. Completion and archiving do not automatically reclaim those resources. Records and associated resources remain available.

**What I want**

I want smart resource cleanup to happen when I archive a completed First Mate session, so completed work does not keep consuming unnecessary disk space. I also want a durable log of the completed task for historical documentation.

Archiving should preserve a useful account of what was requested, what was done, what was delivered, and what was verified, while removing resources that are no longer needed. The archived work should remain easy to find and inspect.

The request concerns completed sessions and their task resources. Archiving a saved project entry is currently a separate action and should not be assumed to authorize deleting the project's shared source folder or other sessions.

**Behavior discussed**

- Archive triggers cleanup on the machine that owns the session. Cleanup can continue in the background, with visible progress and a result showing what was removed, what was retained, why, and approximately how much space was reclaimed.
- Preserve and verify the completion record before removing anything that it depends on. A failed cleanup should leave an understandable result and support a safe retry.
- Use recorded ownership to decide what belongs to the task. Shared resources and files whose ownership is uncertain should be retained.
- Protect unfinished work and unsaved source changes. Archiving active or paused work should not silently stop it or delete its resources.
- Keep historical verification and usage facts readable after cleanup. Recorded results describe the completed work; they should not disappear merely because its temporary workspace is gone.

**Proposed defaults to evaluate**

We discussed deleting task-owned temporary builds, caches, and clean disposable worktrees; retaining dirty worktrees and untracked source; deleting task branches whose commits are safely preserved by integration; and initially retaining unmerged branches so their implementation is not lost.

We also discussed retaining final documents and deliverables, compressing saved conversations and large execution logs while keeping them readable, and removing recovery backups only when their contents are safely preserved elsewhere. Published builds and releases would remain available, with only disposable local copies eligible for cleanup. Shared project folders and shared build caches would remain untouched.

These are proposals from the discussion, not individually confirmed retention rules. Exact retention periods, how to handle older resources with incomplete ownership records, and what unarchiving can restore still need to be settled during the build session.

**Historical documentation I want preserved**

The completion record should capture the original request, task identity and dates, outcome, delivered changes, limitations, stage and assignment summaries, commit and PR references, build or version references, actual verification results and omissions, final documents, and available usage or cost totals.

It should also retain a cleanup log of removed and retained resources, reasons, failures, and subsequent retries. We discussed a searchable record with an exportable Markdown report. This history should provide useful documentation without depending on keeping all of the task's bulky working resources.

**Purpose of the next session**

Build this feature using this brief as the product context. Determine the implementation in that session. This document does not authorize a live cleanup of existing sessions or a deployment.

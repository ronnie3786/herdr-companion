# Feature workspaces

First Mate normally uses one Git worktree and one continuing branch per feature.
Assignments, workflow stages, saved sessions, and Git workspaces have different
lifetimes. Planning before implementation can read the project checkout without
creating a worktree. The first writable assignment creates the feature worktree;
later implementation, review, feedback, builds, and delivery reuse it.

## What changed and why

Previously, every `workspace_mode: isolated` delegation allocated a directory and
branch from its request ID. `source_assignment_id` selected the commit to copy,
not a checkout to continue. Twenty-three sequential writable assignments could
therefore leave twenty-three checkouts, each retaining its own build caches.
Retries and context handoffs already reused the same assignment's workspace.
Replacement assignments and later stages were the main source of multiplication.

The new default makes the feature workspace durable across those boundaries.
Finished changes are committed on the current feature branch. Git history keeps
the earlier revisions; another physical checkout is not needed for each revision.
Branch renaming is supported, with ownership validated against the linked Git
directory and repository rather than an old branch label.

## Delegation contract

| Request | Result |
| --- | --- |
| `read_only`, before a feature workspace exists | Inspect the project checkout; create nothing. |
| `isolated`, default `workspace_strategy: feature` | Create the first feature worktree, then reuse it. |
| `read_only`, after a feature workspace exists | Inspect the continuing feature worktree. |
| `independent` with `independence_reason` | Use a private non-Git scratch directory for work needing no checkout or unfinished result. No feature-worktree reservation or extra Git branch. |
| Exact `source_assignment_id` | Continue or inspect that assignment's owned checkout. A writable continuation selects it as the feature's ongoing workspace. |
| `isolated`, `workspace_strategy: fork`, and `fork_reason` | Create a separate branch/worktree for independent parallel work or an experiment. Keep the existing primary workspace. |
| Retry, recovery, context handoff, or a new feedback round | Keep the existing workspace and branch. |

A fork requires a clean committed source. It includes committed history, not
uncommitted files. The parent integrates selected child commits back into the
feature branch within the authorized scope. A request ID still pins an immutable
workspace plan; retrying the same request does not create another checkout or
change its source. Invalid delegation fields are rejected before allocation.

Default assignments sharing a workspace serialize. The scheduler reserves
pending dispatches, and the supervisor holds an OS workspace lock for the full
Pi execution. Writable assignments take an exclusive lock; read-only workers
can run together under shared locks. The lock is inherited by Pi, so a dead
supervisor does not by itself release a surviving Pi process's ownership.
Live pre-upgrade dispatch locks also fence new work on the same path.
A stopped worker retains its reservation while recovery is unresolved. Yielding
parents reserve their workspace for their own descendants until their assignment
settles, so unrelated queued work cannot interrupt the parent/child handoff.

Nested workers normally use the parent's workspace after the parent records
`fm_wait_for_children` and exits its current turn. The parent resumes its saved
conversation after the children settle. Use an explicit fork when a child needs
independent writable work. Read-only parents still cannot grant writable access.
Read-only is a trusted-agent instruction, not an OS security sandbox. Unmanaged
tools and human editors do not participate in the runtime's locks.

## Choosing which tasks can run together

Second Mate reasons about inputs and writes before delegating, and queues all
independent tasks in the same authorized stage. It does not infer dependencies
from the order of the request, skill names, or a shared feature. The server uses
the explicit workspace mode; it does not classify natural-language task titles.

| Tasks | Routing |
| --- | --- |
| Code cleanup and research using external documentation | `isolated` code worker plus `independent` researcher, at the same time. |
| Code cleanup and an authorized PR-body update from the published diff | `isolated` code worker plus `independent` PR worker using an explicit repository and PR identity. |
| Description of an implementation that is still changing | Wait for the required implementation result before publishing the description. |
| Review or tests of the changing local checkout | `read_only` or `isolated`, with the existing checkout locks and revision checks. |
| Two workers editing the same checkout, or two changing the same external resource | Order the conflicting work. Separate code implementations may use deliberate forks. |

Independent delegation requires a bounded `independence_reason` stating why no
live checkout or unfinished result is needed. Omit `source_assignment_id`,
`workspace_strategy`, and `fork_reason`; conflicting parameters are rejected
before allocation. Include exact skill paths, necessary project instructions,
supplied sources, external target identities, and the already-authorized actions
in the task prompt. Project-local context and repository inference from the
current directory are unavailable in this mode. If the task turns out to need
the live code, the worker reports that dependency to Second Mate.

The scratch directory is durable per assignment request, reused by retries and
handoffs, and absent from the Git workspace catalog and code-verification scope.
Nested independent workers receive their own scratch directories, even under a
code worker. An independent parent cannot grant a checkout to its children.
Missing or redirected scratch directories block execution instead of falling
back to the feature checkout. Host worker limits, session/workspace locks,
model routing, human gates, and durable external-effect receipts still apply.

This mode is a trusted-agent scope, not an OS sandbox. Direct `edit` and `write`
tools are confined to scratch, including symlink checks; arbitrary shell tools
are not generally sandboxed. External services do not participate in workspace
locks, so Second Mate must order conflicting external writes. Automatic recovery
remains conservative: independent work with missing receipts or any mutations
requires inspection. Scratch artifacts stay in place; no Git backup is claimed.

`fm_delegate` returns `queued`, which means accepted for scheduling. Second Mate
must not report a worker as started until authoritative state says `running`.
It can explain known dependencies or checkout waits without polling.

## Recovery and review

Reusing a workspace never runs reset, checkout, clean, stash, or an automatic
commit. Staged, unstaged, and untracked work and ignored build caches remain in
place. Workers inspect current Git state before continuing; the old recorded
`base_revision` is evidence, not a restoration instruction.

Interrupted work uses `fm_recover`; reported failures use `fm_retry`. The existing
stopped-writer, source-backup, effect-receipt, successor-acknowledgement, human-gate,
and recovery-budget checks remain in force. A new assignment cannot substitute
for recovery of a workspace whose owner is still in `recovering`.

Revision-pinned reviews remain pinned. Their source is checked again after
acquiring the workspace lock, before sending the review prompt. A review queued
against a changed revision is blocked instead of silently reviewing another
commit. Stage completion rejects a review made stale by a later fix. Within the
same authorized stage, `fm_retry` can refresh a completed read-only review whose
source revision changed. This retains the old attempt and records a new verdict;
it does not consume the separate failed-repair budget or allocate a worktree.

Once a fork is settled, clean, and its current commit is an ancestor of the
primary branch, verification treats it as integrated history and carries its
suite requirements into the primary workspace. This uses Git ancestry, never a
worker's unsupported claim of integration, and does not remove its checkout.
Dirty or unmerged forks retain their own verification scope.

## Existing features and retention

An existing feature with one retained worktree, or one unambiguous leaf in its
recorded source-assignment lineage, adopts that checkout. A feature with
independent branches requires an exact source assignment, selected from retained
evidence. Names, timestamps, apparent commit counts, or a screenshot never decide
which branch is canonical. No source is silently discarded or copied from a
different checkout. A missing checkout, changed Git identity, detached HEAD, or
unreadable ownership record stops reuse for inspection.

Existing extra worktrees, branches, and caches remain retained. Archiving a
feature still changes visibility only and can occur while work is running.
This update prevents per-stage growth; it does not make ignored directories
automatically safe to delete. Cache cleanup and checkout retirement require a
separate explicit cleanup decision after verifying ownership and live users.

## Compatibility and verification

Install the matching companion wheel and bundled Pi extension on each execution
host. The server advertises `first-mate-feature-workspaces-v1` and
`feature_workspaces: true`. Existing `isolated` callers get the new default without
an API change. Existing request receipts and in-flight dispatches are retained.
Native clients continue to use the existing assignment and Git workspace APIs;
the catalog already collapses assignments that share a physical checkout.
No Mac or iOS app update is required for this behavior.

Independent workers additionally require `first-mate-independent-workers-v1` on
the companion and its matching bundled Pi extension. Existing delegations keep
their original modes; upgrading does not reroute already-queued assignments.

Focused tests use entirely synthetic Git repositories and real detached worker
processes. They cover twenty-three sequential stages on one branch/cache,
restart with staged and untracked edits, explicit forks, legacy adoption,
ambiguous and missing checkouts, retry/recovery, stale review refresh, queued
writer exclusion, concurrent independent forks, nested children, and legacy
process locks. Run:

```sh
python3 -m unittest tests.test_first_mate_workspaces tests.test_first_mate_runtime tests.test_first_mate_store tests.test_first_mate_recovery tests.test_first_mate_reliability tests.test_first_mate_verification_runtime
node --test pi-semantic-bridge/test/first-mate.test.mjs
```

# First Mate stability and automatic recovery

First Mate supervises both its execution engine and the work it owns. A live
process or a stream of tokens is not proof that the assignment is advancing.
The controller runs on the companion server with all client windows closed.
It does not use cron, wake a model every hour for healthy work, or require the
human to keep asking for status.

## Recovery ladder

| Layer | Detection | Response |
| --- | --- | --- |
| Storage | Failed durable writes or insufficient admission reserve | Retain the last committed state, discard failed temporary writes where possible, and retry with 1–30 second backoff. Defer new launches until both state and workspace volumes have the configured reserve. Never auto-delete worktrees or build output. |
| Scheduler guardian | Independent thread checks every 10 seconds | Restart a dead scheduler under the original manager lock, at most three times per hour. Never start a second scheduler over a still-live/hung one. |
| Ordinary reconciliation | Missing launch spool, process receipt, or settled child continuation | Reattach/reconcile the existing durable identity; never treat process exit as task success. |
| Hourly stability sweep | Authorized running/recovering stage with unchanged progress | Compare durable progress, bounded Git evidence, and child outcomes. Token traffic, generation changes, and repeated identical progress reports do not reset the progress clock. |
| Evidence assessment | A worker looks stale | Run one bounded read-only advisor. A legitimate long build may continue under a bounded lease; uncertainty is not proof of a stall. |
| Nudge | Advisor recommends steering/handoff, or cannot answer before its deadline | Send one durable, idempotent progress/handoff request. Allow five minutes by default to report concrete progress, declare an evidenced wait, or hand off safely. |
| Verified restart | Nudge produced no progress | Request a graceful abort through the owning supervisor. Wait for its writer lock to clear. An unconfirmed stop blocks recovery; it never permits a competing writer. |
| Checkpointed continuation | Stopped worker has verifiable effects and a safe next action | Preserve source changes, obtain an independent recovery brief, and queue a fresh execution in the same assignment and workspace. Mutation is fenced until that executor acknowledges the recovery checkpoint. |
| Circuit breaker | Two unsuccessful continuations, unsafe effects, missing evidence, unconfirmed stop, or backup failure | Block with the actual reason and retained evidence. Configured notifications can ask for direction. No silent stage advance, publishing, or repeated external action. |

The hourly interval is a sweep cadence, not a guarantee that every slow task is
stalled after precisely one hour. Evidence can defer intervention. Active rescue
deadlines are checked about every ten seconds; they do not wait another hour.
An overdue sweep runs when the server resumes. Its next deadline and per-worker
intervention state survive a companion restart.

## Durable current position

Workers receive `fm_progress(summary, next_action, evidence, wait_seconds?)`.
Use it at meaningful milestones and before long builds/waits, not as a heartbeat
or polling loop. The store retains the current position in assignment metadata
and keeps prior checkpoints in the journal, including the producing generation,
native session, server timestamp, evidence, and next action.

A wait lease is at most one hour. Repeated unchanged evidence cannot renew the
same position's lease forever. Genuine progress or new evidence can establish a
new position. Reports are model-authored evidence, not independently proven task
completion; the advisor also receives bounded recent tool/session evidence.

Successors receive retained progress, workspace observations, and the latest
handoff-document reference. They should read the latest checkpoint and targeted
source rather than re-read every predecessor. Four handoffs with the same observed
position inside one sweep interval trip a churn breaker before another successor
is launched. The latest handoff is retained, not deleted.

## Safe effects and ownership

New managed workers durably record mutating tool starts **before** allowing them
to execute, then record completion. An unwritable ledger blocks the tool. Direct
`edit`/`write` calls are classified as workspace-local only after canonical path
checking; shell commands and unfamiliar tools are conservatively external.

Automatic writable recovery requires the versioned ledger. Missing, malformed,
incomplete, or failed external receipts stop it. A successful tool receipt still
does not prove a remote business operation completed. The read-only advisor
supplies a recovery checkpoint. If it cannot establish the next action, but the
writer has stopped, the backup is intact and all external effect receipts are
complete and nonfailed, a fenced inspection successor may read the exact
predecessor session and acknowledge a verified next step or request a real human
decision. Every successor acknowledges before mutation. Missing or failed
external receipts remain blocked. The system does not replay the original prompt
or retry a deployment because its process died.

Older executions without the ledger require explicit recovery direction.
A `read_only` workspace is an instruction, not a tool sandbox in current Pi.
Normal configured tools remain available, but an effect-capable tool used outside
a managed isolated worktree requires inspection rather than automatic recovery.
Automatic stability and recovery advisors are explicitly restricted to read-only
tools; ordinary advisors retain their existing tools. Ordinary known
handoffs continue through their verified handoff protocol. Neither monitoring nor
recovery grants new stage, deployment, publication, cleanup, or human-gate authority.
Queued human direction takes precedence over automatic intervention.

Controls use stable identities and frozen payloads/deadlines across failures.
Old job spools cannot relaunch a saved handoff after a newer generation has taken
ownership. Explicit human `fm_recover` can release a reliability blocker atomically;
it does not need a second Resume and cannot override an intentional Pause or a
pending human checkpoint.

## Work preservation

Before automatic recovery of a stopped writable executor, First Mate captures a
private recovery archive from its service-owned isolated worktree:

- HEAD and assignment/session provenance;
- binary-capable tracked changes against HEAD;
- a separate staged patch;
- non-ignored untracked regular files;
- untracked symlink targets as metadata, without following or extracting them.

These archives live under `first-mate-runs/recovery-backups`. Captures use atomic
publication, restrictive permissions, bounded Git subprocesses, source-change
checks, and a recorded SHA-256 verified again before continuation. No commit,
stash, reset, branch deletion, or automatic restore is performed.

Source payload is capped at 64 MiB per archive (up to 72 MiB including bounded ZIP
metadata), and the archive directory has a 1 GiB quota. Exceeding the quota requires
operator direction; existing archives are not silently deleted. Temporary free-space
pressure instead waits and retries. Archives are taken at stopped recovery boundaries,
not continuously during every edit or ordinary context handoff.

**These are recovery archives, not full or off-machine backups.** They omit ignored
build outputs, Git object storage/history, and nested submodule working trees.
They cannot protect against loss of the entire volume. Keep normal machine/volume
backups. Inspect archives and current workspace state before any explicit restore.

## Stranded coordination

An hourly sweep also looks for a stage still marked running after all assignments
settled, with no coordinator job or queued message to collect them. It queues a
system wake-up to synthesize the existing outcomes, finish the current stage, or
explain its blocker. That message is evidence, not new human authorization.
Uncertain or missing coordinator effect receipts block another automatic turn.
Two unsuccessful coordinator kickstarts block for direction instead of looping.
Queued assignments and crash gaps continue through normal durable reconciliation.

## Mac visibility

Open **First Mate → Workflow → Stability & recovery** for:

- guardian status and automatic-recovery policy;
- sweep interval, last sweep, and next scheduled sweep;
- each assignment's current progress checkpoint and next action;
- recent stability decisions, nudges, stop requests, and continuations;
- recovery facts, archive path/checksum, and exact session/handoff links.

The chat distinguishes monitoring failure, recovery in progress, and a real blocker.
Active features become **Unverified** when monitoring/refresh fails instead of
presenting an old running row as live work. Native clients never rewrite workflow
facts based solely on engine health.

## Configuration and compatibility

Defaults in the private `[first_mate]` section:

```toml
auto_recovery = true
sweep_seconds = 3600
nudge_grace_seconds = 300
minimum_free_mb = 1024
```

The sweep range is 300–86,400 seconds, grace range 60–3,600 seconds, and reserve
range 64–102,400 MiB. `auto_recovery = false` disables automatic stale-work rescue
and missing-outcome continuation; explicit recovery remains available. The engine
still reconciles receipts, supervises itself, and enforces the existing handoff,
child-continuation, and human-stage protocols.

Requires matching companion server and Pi extension package. Capability
`first-mate-reliability-v1` is additive to `first-mate-runtime-health-v1`. The Mac
surface uses optional fields; older clients continue to read the API, and older
servers show upgrade guidance rather than invented health. No notification provider
is enabled by default. Existing Message Hub configuration may notify for stage
checkpoints, unknown dispatches, exhausted recovery, and reliability blockers.

An app-only update does not install these server/extension changes. Use the
repository's normal separately authorized update procedures. Installing this
source is not permission to restart unrelated services or mutate existing work.

## Explicit limits

- A guardian thread is independent of reconciliation, not of the backend process,
  Python runtime, OS, or storage device. A live hung thread is surfaced but is not
  unsafely replaced. Whole-process/host failure still needs the service manager.
- Progress detection is evidence-based, not a proof of useful reasoning. Long
  builds may legitimately be quiet; advisors and leases reduce false positives.
- Arbitrarily detached processes outside the managed supervisor's process group
  are outside its ownership contract. Missing effect receipts remain a blocker.
- No persisted log or phone notification is guaranteed while storage itself is
  unwritable. In-memory engine health remains available while the API responds.
- Authentication failures, genuine human decisions, archive/quota problems, and
  uncertain external outcomes are not repaired by endless model restarts.

## Verification

`tests/test_first_mate_reliability.py` exercises deterministic clock advances,
no-progress token chatter, bounded build leases, crash-safe nudge replay, guardian
fencing/budgets, stage gaps, handoff churn, backups, unsafe effects, disabled policy,
and human-gate preservation. Its real detached-process scenario nudges an alive
but idle synthetic worker, stops it, starts a checkpoint-fenced successor, and
finishes at the human stage boundary without another human message.

The storage-fault suite, native contract/render tests, Pi extension tests, and
existing First Mate store/runtime/acceptance suites cover the integration. Tests
use temporary synthetic repositories/providers; they never fill a real volume,
restart a production backend, or contact a real model/notification provider.

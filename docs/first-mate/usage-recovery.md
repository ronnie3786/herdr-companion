# First Mate usage accounting and recovery

Companion **0.76.1b1** refreshes complete-history usage outside interactive list,
chat, details, and saved-session requests. The API remains compatible with existing
native, web and Pi clients. Install the companion package separately; an app update
does not install this service.

## Read and refresh behavior

One background owner computes usage from the managed ledger and job inventory.
Requests submit compact immutable inventory snapshots and immediately return a
cached projection or an unavailable metadata projection. They never wait on the
accounting worker's lock, JSON parsing, hashing or historical path resolution.
Missing usage is unknown, never confirmed zero. Started but unbound jobs can still
be discovered through a strict, bounded header read even when usage is disabled.

The pending queue coalesces by feature and holds at most 64 projections. Circular admission and dispatch share a cursor so fixed-order polling larger than
the queue cannot starve later features. A full queue retains the nearest keys after
that cursor; other work retries on a later read. At most one daemon
thread runs, and it exits when idle. Unchanged inventory is revalidated at most
every five seconds after a successful or failed attempt. Changed snapshots can
queue sooner. Requests with changed ownership, assignments,
source paths or native IDs cannot reuse the old full projection. They get a
metadata projection until their new snapshot is accounted. Cached usage never
authorizes session access, launch decisions or workflow verification.

Usage keeps the existing `complete`, `partial`, and `unavailable` coverage states,
with additive `refresh_state` values:

- `pending`: no projection for the current inventory yet; cost is unavailable.
- `cached`: the projection was validated within `validation_age_bound_seconds`
  (30 seconds). Complete means complete coverage of that validated snapshot,
  not a claim that an active worker has made no further calls. `updated_at` is
  source/feature time, not validation time.
- `stale`, `failed`, or `stopped`: previously known values are explicitly stale
  and at most partial; cold values remain unavailable.

Ordinary revalidation of unchanged sources does not change conditional response
versions. Failure, overdue coverage, topology changes and changed totals do.
`/api/v1/first-mate/capabilities` includes content-free `usage_refresh` diagnostics:
mode, enabled/stopped state, queue/cache counts and capacity, refresh interval,
validation-age bound, completed/failed attempts, and last-success age. These
supplement scheduler health; they do not replace measuring the conversation routes.

## Integrity and resource limits

The synchronous accounting engine retains existing canonical duplicate/conflict,
model, cost and JSON-safe token semantics. One bounded LRU retains 4,096 source
versions and their last known values. It validates device, inode, size, mtime and
ctime around each scan, including the open descriptor. Rewrites, replacement,
partial records, mismatched headers, unreadable files and symlink escapes cannot
silently become complete new coverage. Transient failures are retried; definitive
identity failures evict prior claims. Files are opened relative to the managed
root with no-follow directory traversal and a nonblocking regular-file check.

This implementation deliberately rescans a **changed** source in the background.
It does not persist totals or append offsets, avoiding a second durable ledger
and preserving full-record deduplication semantics. Unchanged sources reuse their
validated summary. A process restart rebuilds from original history; it never
rewrites or deletes that history. Cancellation is checked between bounded records,
and stopping waits at most one second for optional accounting. Detached Pi workers
retain their existing lifecycle. An old blocked thread is never replaced by a
second accounting owner during same-instance restart.

Job JSON parsing has a separate 4,096-file cache. Every read revalidates the current
filesystem signature, including ctime; changed files are checked again after
parsing. Returned dictionaries are independent copies. This is not a TTL inventory
used for scheduling or ownership. Continually changing or inaccessible inventory
fails explicitly rather than omitting an active dispatch. A corrupt historical
job record can therefore keep inventory-dependent reads unavailable until repaired;
this cache does not mask corruption or replace authoritative inventory.

Saved-session pages retain at most the requested page and one bounded record in
memory, preserve exact counts/cursors, and stop at their initial observed EOF.
They still scan that transcript to count messages. Ownership, managed-root,
regular-file and exact-header checks are independent of accounting availability.
Directory inventory, small header discovery, context/verification enrichment, and
transcript reads still perform synchronous work. Slow disks and unusually large
individual transcripts can therefore still delay a request. A concurrently
appending transcript is a bounded snapshot; a detected replacement, shrink or
header rewrite asks the caller to retry.

## Recovery switch and rollout

Set this only in the affected computer's private configuration:

```toml
[machines.desktop.first_mate]
usage_enabled = false
```

Use the configured machine ID. The default is `true`; the equivalent environment
setting is `HERDR_FIRST_MATE_USAGE_ENABLED=false`. Validate configuration and use
a guarded companion restart. Verify **effective** `usage_refresh.enabled == false`
after restart, rather than trusting the TOML alone or scheduler liveness. Keep
accounting disabled until the replacement passes correctness, synthetic scale and
isolated populated-history checks. Then deliberately enable it and repeat the
normal authenticated-route checks, including invalid-token rejection.

Stage the exact reviewed, verified wheel in an inactive versioned runtime. Preserve
service definitions, the private configuration, consistent SQLite backups, session
files and the previous runtime. Prove active workers are detached before restart,
and verify they survive or complete normally afterward. Never bypass an unknown
child-process guard or force-kill unrelated agents. Confirm list, lead, every active
chat, overview/details, representative large saved sessions and concurrent reads.

The preferred accounting rollback is the tested replacement with usage disabled,
followed by a guarded restart. Keep the previous runtime for service-startup
rollback, but independently establish whether that version honors the switch.
Do not restore an old database over new worker history merely to revert code.

## Reproducible scale check

```sh
.venv/bin/python scripts/benchmark-first-mate-reads.py
```

The benchmark generates synthetic history only: at least 1 GiB across 832 sessions,
1,200 large job records, eight features, and a 40 MiB saved session. It asserts
correct deduplicated totals and a **five-second per-read target**, well below the
native 15-second timeout, for cold, warm and three concurrent list/chat reads and
the saved-session page. A deliberately blocked accounting worker proves those
reads do not depend on its completion. It reports actual bytes and measured times;
results depend on the machine and are not a production SLA. Unit tests use events
and scan counts, rather than wall-clock thresholds alone, for concurrency and
shutdown correctness.

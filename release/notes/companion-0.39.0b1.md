# Companion 0.39.0b1 — First Mate reliability

Matching server, CLI, web assets, and Pi extension package for the Mac 0.39 preview. Existing authenticated First Mate endpoints remain compatible; `first-mate-runtime-health-v1` and `first-mate-reliability-v1` add optional health and recovery fields.

The server performs persistent hourly progress checks without a client window or continuous model polling. Stale assignments receive a bounded read-only assessment and nudge. Automatic continuation requires verified writer stop, preserved work, trustworthy effect receipts, an assessed safe next action, and successor acknowledgement. Human stage boundaries remain authoritative.

A guardian restarts dead scheduler threads with a retry budget; storage failures use bounded backoff instead of killing monitoring through diagnostic-write cascades. New launches require free-space reserve. Managed-worktree recovery ZIPs retain tracked/staged patches and non-ignored untracked source under size and quota limits. No automatic deletion or restore occurs.

Defaults in private `[first_mate]` configuration: `auto_recovery = true`, `sweep_seconds = 3600`, `nudge_grace_seconds = 300`, `minimum_free_mb = 1024`. Set `auto_recovery = false` to require explicit missing-outcome recovery. Normal configured role tools remain available; automatic recovery advisors are restricted to read-only tools. A read-only workspace label alone never proves effect safety.

## Installation and rollback

Use the repository's **Update the server** runbook. Verify artifact hashes, install the exact wheel into a new versioned Python 3.11+ environment, run `scripts/verify-installed.py`, validate the private configuration, and take consistent SQLite/state backups before switching the selected companion service. Update matching CLI wrappers and the installed Pi extension. Preserve private configuration, state, active executions, upstream Herdr, and the previous runtime for rollback.

An app-only update does not activate server recovery. Already-started executions keep their original extension and ownership. Older executions without effect receipts require human inspection; they are not blindly replayed. Unstarted/new executions use the matching installed extension. Rollback restores only service/runtime definitions unless an independently reviewed data-recovery plan requires otherwise; never overwrite new user data with an old database.

Existing 0.38 Agent Profiles and First Mate chat, archive, model routing, and usage remain included. See `docs/first-mate/reliability.md` for operating limits. A guardian thread is not a whole-process/host supervisor, and local recovery archives are not full or off-machine backups.

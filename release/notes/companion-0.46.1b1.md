# Herdr Companion server 0.46.1b1

First Mate now reports why recovery stopped and provides a usable next action.

- Coordinator status includes the recovery count, remaining budget, progress lease evidence, and whether a worker recorded an outcome. Repeating exhausted recovery no longer increases its counter.
- A new human direction can explicitly reset the bounded recovery budget and handoff history. A request to stop a worker and continue waits for its verified stop, including during a progress wait lease. Human checkpoints and uncertain external writes remain protected.
- Read-only shell probes with nonzero results no longer look like failed external writes. Unknown or partially failed external mutations remain blocked for inspection.
- Selective revision preserves unrelated edits in the human checkout and keeps a running stage available for replacement work. Isolated code and pinned revision evidence still require validation.
- Coordinators have a ten-minute default deadline. Interrupted turns report completed and unconfirmed tool operations, and use the existing configured notification channel. Stranded running stages are checked every minute.

## Compatibility and installation

This is a server-only update with the matching bundled First Mate Pi extension.
Existing Mac, iOS, and web clients remain compatible. There is no database format
migration. The Mac app updater does not install this package.

Install the wheel into a new versioned Python 3.11+ environment, retain private
configuration and state, validate configuration and Fleet paths, take a consistent
backup, then switch the companion and its CLI/Pi integration using the server
update procedure. Preserve the previous runtime for rollback.

## Verify the behavior

Open a First Mate feature and ask for recovery status. Its coordinator can now
name the remaining budget, wait lease evidence, and permitted remedy. If a budget
is exhausted, explicitly ask to reset recovery after inspecting retained effects.
To end a long wait, ask to stop that worker and continue. Neither action authorizes
new workflow stages, external publication, or bypassing a human checkpoint.

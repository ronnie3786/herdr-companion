# Recovery investigation and remedies

The September 2026 blocking report was checked against the current companion
source before implementation. Operational session data and machine identities
remain outside the repository.

| Report area | Finding and disposition |
| --- | --- |
| Failed tool receipts | Confirmed that failed external receipts remain uncertain. A failed command can have partial effects, so the blanket proposal to clear every failed receipt was rejected. Conservative observational shell classification now lets harmless probes recover; unsafe calls include bounded inspection evidence. Older external-labelled receipts are not retroactively declared safe. |
| Handoff churn | The limit is retained to prevent an endless loop. A new human direction can reset its history with `fm_recover(reset_budget=true)`, or change scope through `fm_revise`. Nudges prefer progress and continuation before handoff. |
| Recovery exhaustion | Counters now stop at the cap, status includes remaining budget and remedy, and a human reset is audited and bounded to once per direction turn. Durable replay never stops a successor. |
| Wait leases | Leases require their live requesting execution and can be revoked by a new progress receipt. Explicit human stop-and-continue waits for verified stop and fences the successor for post-stop inspection. |
| Selective revision | The store already leaves a selective revision running. Tests now establish that completed carry-forward remains delegable; the charter requires replacement work before closing it. Inactive-stage refusals name the next action. |
| Coordinator deadlines | Default increased from three to ten minutes. Existing durable tool request/response records produce a completed/refused/unconfirmed operation journal after interruption. Unknown operations are not replayed automatically. |
| Planned handoff budget | Source inspection confirmed ordinary handoffs already increment generation separately from failure recovery. That behavior is retained. |
| Shared checkout carry | Removed the clean-tree requirement for shared checkouts. Isolated work and explicitly pinned revisions retain their evidence checks. Charters and common Git-command guardrails prohibit cleaning human edits. This is not a general shell sandbox. |
| Parked work | Normal stage completion already emits a notification event. Interrupted coordinators now also notify through the configured channel; running-stage coordinator gaps are checked every minute. Intentional human checkpoints remain parked. |
| Outcomes followed by blocked status | The suspected completed-outcome overwrite was not reproduced in current source. Regression tests protect completed outcomes from late configuration failure and SIGTERM. `has_outcome` now identifies an actual outcome receipt, independently of verdict or process exit. A findings document with a blocked verdict remains blocked. |
| Concurrent shared artifacts and external writes | The broader isolation/serialization concern remains. Read-only review work still uses a shared checkout and external writes are not generally resource-locked by this patch. Use pinned revision evidence and one authorized writer per external resource. |
| Operator commands | Host scoping and event cursors are documented. The external `runner-task` implementation is not part of this repository and was not changed. |

See [runtime behavior](runtime.md#recovery-remedies-and-retained-operations) for
API fields, authorization rules, and limits. A server rollout preserves parked
features; it does not itself authorize restarting their work.

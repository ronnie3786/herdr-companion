# Herdr Companion server 0.49.0b1

Matching companion and Pi package for the quieter First Mate chat.

- Adds `first-mate-quiet-chat-v1`. When a worker outcome, authorized follow-up,
  or stability sweep wakes the coordinator, its closing message becomes a private
  `coordinator.note` journal event instead of a chat message. It reaches the chat
  only when the update needs the human (a human checkpoint, exhausted recovery, or
  a configuration block) or the turn leaves nothing running and nothing queued,
  including when the turn itself failed. Each assignment's decision is delivered
  separately, and a report for an unchanged workflow state is never repeated
  before the human's next message.
- Worker outcome updates point to the evidence (verdict, short excerpt,
  assignment and Document IDs) instead of copying the full report into the
  coordinator's conversation.
- New coordinator tool `fm_notify_human`: one brief background notice per turn
  for a decision, blocker, or finished deliverable. `fm_complete_stage` limits the
  stage result to 1,200 characters and the recommendation to 400.
- The coordinator charter presents First Mate as the feature's lead developer and
  treats the stage checkpoint as its report.
- `fm_messages` gains a `visibility` column. The first start labels existing
  history once and never changes message text: replies to routine updates are
  hidden when their turn already posted a checkpoint or a later report followed,
  and kept when the human answered them. Board messages, feature summaries,
  the web view, and coordinator rotation use only conversation rows; snapshots
  keep every row with its label.

## Install separately

Use the server update procedure in `herdr_harness/README.md`. Build/install in a
new Python 3.11+ runtime, preserve private configuration, take a consistent state
backup, validate the package and configuration, then explicitly switch the
companion and matching CLI/Pi integration. The database change is additive;
retain the prior runtime and a consistent backup for rollback. An older runtime
ignores the new column. Do not replace a live database with an older backup after
new user writes without a separate recovery plan.

The signed Mac updater installs only the app. Publishing this package performs no
server cutover and no iOS installation.

## Verify

Confirm `first-mate-quiet-chat-v1` in the authenticated capabilities. On a
disposable feature, request a plan with parallel workers and confirm one reply,
one stage result, background notes in the journal, and no message per worker.
Test an older native client against the new server before updating clients.

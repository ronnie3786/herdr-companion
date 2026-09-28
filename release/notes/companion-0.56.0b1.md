# Herdr Companion server 0.56.0b1

The lead First Mate: one continuing conversation across every First Mate
feature on a machine, behind the Mac First Mate HUD and chat window.

- Adds `first-mate-lead-v1`, advertised by `GET /api/v1` and
  `GET /api/v1/first-mate/capabilities`.
- `GET /api/v1/first-mate/lead` returns the lead's summary (its newest message,
  whether a reply is unread, whether it is answering), or null before first use.
  It is one bounded read, cheap enough to poll. `POST /api/v1/first-mate/lead`
  creates the lead on first use; there is exactly one per ledger.
- The lead is a feature row with `kind: "lead"`, so it reuses the ordinary
  feature routes: detail and board, messages, attachments, model settings, read
  markers, and feedback. It never appears in the feature list, the fleet,
  notifications, or control discovery, and refuses archive, pause, resume,
  cancel, labels, and workflow stages.
- Lead turns run as managed Pi conversations with their own charter and tools:
  `fm_fleet`, `fm_feature_status`, `fm_read_document`, `fm_mark_read`,
  `fm_relay`, and `fm_create_feature`. `fm_relay` posts the human's own words to
  a feature as their message (human turns only), records the relay in its
  metadata and journal, and marks that feature read. The lead has no stage
  authority and never releases a gate.
- It uses the host's First Mate coordinator model and thinking, with the same
  per-conversation override as a feature. Replies get skims from
  `[first_mate] skim_model`.
- Context: after a reply that reaches `context_target` (150,000 tokens by
  default), the next turn starts a fresh session carrying the last 30 messages.
  The lead also keeps Pi's automatic compaction for one turn that would
  overflow first.
- A message to the lead may carry `context`: a bounded, read-only snapshot of
  the human's features on other machines, which the lead's tools cannot reach.
  It is stored apart from the conversation and never returned to clients.
- `first-mate.sqlite3` gains `fm_features.kind`, a unique index for the lead, and
  `fm_message_context` (schema 16); every existing row stays a feature.

## Install separately

Use the server update procedure in `herdr_harness/README.md`. Build/install in a
new Python 3.11+ runtime, preserve private configuration, take a consistent state
backup, validate the package and configuration, then explicitly switch the
companion and matching CLI/Pi integration. The companion and its bundled First
Mate Pi extension must be upgraded together. The database change is additive; an
older runtime would list the lead as an ordinary feature, so retain the prior
runtime and a consistent backup for rollback.

The signed Mac updater installs only the app. Publishing this package performs no
server cutover and no iOS installation.

## Verify

Confirm `first-mate-lead-v1` in the authenticated capabilities, call
`POST /api/v1/first-mate/lead`, then send the returned feature a message and
check that a reply arrives. See docs/first-mate/lead.md.

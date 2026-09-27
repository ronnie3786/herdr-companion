# Herdr Companion server 0.52.0b1

Skims for long First Mate replies and HUD chat answers.

- Adds `first-mate-skim-v1`. A finished conversation reply of at least
  `skim_min_words` words (default 80) — First Mate replies, stage results,
  notices and escalations, and completed HUD chat turns — gets a pending skim in
  the same write, then one tool-free Pi inference (`first-mate-skim-v1` profile:
  packaged prompt `skim-v2`, format `breath_tight`, no tools, extensions, skills
  or context files, retries and compaction off, neutral temporary workspace,
  60-second limit) on a pool of two workers. Replies are never delayed or
  changed. A skim is attempted once per reply; one cut short by a restart is
  resumed once.
- The reply is segmented and the model's Skim markup normalized on the server
  (a port of the Skim lab's reference that reproduces its conformance vectors);
  runaway output is rejected. Board, snapshot and HUD turn responses carry an
  optional `skim` with `status`, versions, and, once ready, the normalized
  `document`, the segment table (ids, kinds, offsets, line ranges; never text) and
  `reply_sha256`. Clients slice excerpts from the reply they already have. A
  landed skim changes the board version.
- New `[first_mate]` settings: `skim` (default on), `skim_model` (defaults to
  Pi's default model), `skim_thinking` (default `low`), `skim_min_words`,
  `skim_hud_chats`, and `skim_backfill_hours` (replies from the last 24 hours that
  predate the update are skimmed once). A provider key the skim model needs goes
  in the private configuration's `[environment]` table when the companion runs
  under launchd.
- The model sees only the reply and the human question it answers. Logs carry
  ids, statuses and timings, never reply or skim text.
- `first-mate.sqlite3` gains the `fm_message_skims` table (schema 14); message
  rows are never modified. HUD chat skims live in `skim.json` beside each turn.

## Install separately

Use the server update procedure in `herdr_harness/README.md`. Build/install in a
new Python 3.11+ runtime, preserve private configuration, take a consistent state
backup, validate the package and configuration, then explicitly switch the
companion and matching CLI/Pi integration. The database change is additive; an
older runtime ignores the new table. Retain the prior runtime and a consistent
backup for rollback.

The signed Mac updater installs only the app. Publishing this package performs no
server cutover and no iOS installation.

## Verify

Confirm `first-mate-skim-v1` in the authenticated capabilities and the `skim`
object in `GET /api/v1/first-mate/capabilities`. On a disposable feature, ask a
question with a long answer and confirm the reply carries `skim.status` `pending`
and then `ready` within a few seconds. See docs/first-mate/skim.md.

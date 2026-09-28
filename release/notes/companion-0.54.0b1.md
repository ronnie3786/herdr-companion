# Herdr Companion server 0.54.0b1

The First Mate fleet summary and read markers behind the Mac First Mate chat
window and its Dock badge.

- Adds `first-mate-fleet-v1`, advertised by `GET /api/v1` and
  `GET /api/v1/first-mate/capabilities`.
- `GET /api/v1/first-mate/fleet?view=active|archived|all` returns one small entry
  per feature: label, emoji, a status that separates **Your turn** from **Ready
  for review**, the Plan/Build/Review/QA/PR/Merge step from the current stage, a
  one-line "now", the latest message (with its skim sentence when one is ready),
  the read marker, unread, and whether First Mate is working on a reply. It is
  one SQLite query and never scans job files or session usage, so polling it is
  cheap.
- `POST /api/v1/first-mate/features/{featureId}/read` stores a per-feature read
  marker so every client agrees on what is unread. It only moves forward, so
  replays and racing windows are harmless.
- `POST /api/v1/first-mate/features/{featureId}/hud` sets or resets a feature's
  short label (24 characters) and emoji. Without one, the server picks a stable
  default emoji from the feature ID with the same rule the Mac app uses.
- These are presentation writes: they never wake First Mate, enqueue work,
  append events, change status or revision, reorder the list, or change the Agent
  view board version.
- `first-mate.sqlite3` gains the `fm_feature_presentation` table (schema 15);
  existing rows are never modified. Older clients ignore the new routes.

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

Confirm `first-mate-fleet-v1` in the authenticated capabilities, then call
`GET /api/v1/first-mate/fleet` and check that every non-archived feature is
listed with `hud_status`, `emoji` and `unread`. See the fleet summary section of
docs/first-mate/build-contract.md.

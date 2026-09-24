# Herdr Companion server 0.45.0b1

Provides bounded First Mate data for the Mac 0.45.0-beta.1 Dashboard and Agent view, which stop re-downloading and re-sorting entire First Mate histories (often 15–20 MB of Pi telemetry per feature) every few seconds.

- Adds `GET /api/v1/first-mate/features/{featureId}/board`, a bounded Agent view projection with newest messages, recent journal events, trimmed assignments, and bounded sessions. It is built from SQLite alone and carries an opaque version; an unchanged poll with `if_version` returns only the version.
- Adds opt-in `?events=journal` to First Mate feature detail. It omits only Pi telemetry (`pi.*` events). The default response still returns every event.
- Feature detail and board responses add `event_cursor`, the highest event sequence including telemetry. Feature summaries add `activity_at`, the latest journal or message activity, which telemetry never moves, and `awaiting_turn`, which marks a coordinator parked until a human replies.
- Advertises `first-mate-board-v1` and `first-mate-journal-events-v1`. The board and journal-only detail read without taking the SQLite writer lock and never decode telemetry. Feature lists no longer scan telemetry to find attention events.

Compatibility: all additions are optional and additive. Older Mac, iOS, and web clients keep working unchanged, and newer clients must fall back to feature detail when the capabilities are absent. On first start the server adds SQLite indexes, including a partial index over non-telemetry events; this one-time step may take a moment on large ledgers.

Install the wheel into a new Python 3.11+ versioned runtime. Preserve the private configuration and state, take consistent SQLite backups, and update the companion service, matching command wrappers, Pi extension, and enabled workers. Keep the prior runtime and service definitions for rollback. Follow `herdr_harness/README.md` under “Update the server.”

This package does not install or replace the Mac app. The Mac app is distributed separately through its signed update feed.

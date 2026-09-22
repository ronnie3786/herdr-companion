# Companion 0.35.0 Preview 1

This companion package supports the shared First Mate Chat controls in the matching Mac preview.

- **Feature attachments:** authenticated, bounded uploads belong directly to a First Mate feature; no terminal pane or arbitrary project path is substituted. Uses the existing 20 MiB upload policy and private attachment storage.
- **Coordinator context:** feature details expose the latest measured context for the exact current coordinator session, with its context window, managed-handoff target, and observation time. This is separate from cumulative feature and worker billing usage. Invalid or unavailable measurements stay unknown; a fresh session never inherits its predecessor's usage.
- **Safe model changes:** an established session must be idle and a change must carry explicit confirmation, its exact native session ID, and the settings revision. Claims, queued work, stale sessions, and conflicting settings are rejected. Identical uncertain retries retain their request identity; settings never start a turn or reset a session.
- **CLI:** `herdr-first-mate set-model` adds `--expected-session-id` and `--confirm-session-model-change`. Confirmation is never inferred. Read the command's help before changing an existing session.

## Compatibility

The new capabilities are `first-mate-attachments-v1`, `first-mate-context-v1`, and `first-mate-safe-model-settings-v1`. Existing clients continue to use First Mate text chat. Older model-setting clients receive a descriptive rejection for unsafe established-session changes; use the matching Mac app or updated CLI. Existing initial model requests retain their four-field format.

First Mate still uses managed checkpoints and a fresh coordinator at a safe turn boundary near its configured threshold. Ordinary Pi compaction remains disabled. Worker models and human workflow checkpoints are unchanged. This package also includes the preceding First Mate Git, on-demand agent-awareness, and pinned architect-review improvements.

## Install separately from the Mac app

The Mac signed-feed updater does not install this server package or restart services. Follow **Update the server** in `herdr_harness/README.md`:

1. Verify the wheel's source revision and SHA-256 from the release assets.
2. Install into a new versioned Python 3.11+ runtime; keep the existing private configuration, state, attachments, and prior runtime.
3. Verify the installed package and configuration. Wait for managed work to reach an approved safe stopping point and take consistent backups before switching services.
4. Update matching CLIs, the bundled Pi package reference, and enabled companion workers together. Preserve their settings and the separate upstream terminal service.
5. Verify authenticated health, retained data, and the three new First Mate capabilities. Keep the previous runtime and service definitions for rollback.

Publication of this package is not evidence that any installed server was upgraded.

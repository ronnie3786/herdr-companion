# Companion 0.30.0b1

This companion package supplies the server, API, browser, and CLI support for the 0.30.0 Mac preview.

## Changes

- **First Mate usage and cost:** additive `first-mate-usage-v1` responses report per-session, per-agent, child-tree, and whole-task model usage and Pi-estimated cost. Retained coordinator history, nested workers, retries, handoffs, and recovery advisors are counted once. Missing or partial coverage remains explicit, and existing saved usage is collected without invoking a model.
- **Smart Rename:** `smart-rename-v1` enforces a one-shot, tool-free naming run with the requested model and thinking level. The profile never receives tools or topology data, and provider or validation failure cannot be mistaken for a successful rename.
- **Response Brief length:** `responseBriefs.lengthPolicyVersion` 2 advertises Minimal, Medium, and Long. Requests capture the chosen policy, legacy receipts remain replayable, and the server validates the additive `responseBriefLength` field without changing older clients' payload behavior. Mac-side baseline recovery prevents unverified history matching and duplicate replacement submissions.
- **Read-only tab-color discovery:** `chat-tab-colors-v1` accepts authenticated, per-installation publications and exposes assigned, unassigned, unavailable, and stale discovery data. Updated `herdr-control` and `herdr-hud-chats` commands add color filters and grouping. Agent-side color mutation is rejected, and no client imports or synchronizes another client's local values.
- **First Mate archive:** `first-mate-archive-v1` adds deterministic active, archived, and all views plus idempotent archive and unarchive actions. Archive remains independent of workflow state, preserves every feature record and link, allows running work to continue, and removes archived features from default lists and attention counts. Database migration is additive.
- **PR Review compatibility:** pop-out windows and enhanced native diff styling are Mac-only. Review hosts need only the existing `pr-review-v1` behavior; this package does not add a new PR Review API for those presentation changes.

## Installation and compatibility

Install the wheel in a new versioned Python 3.11+ environment and follow the [server update procedure](https://github.com/ronnie3786/herdr-companion/blob/companion-v0.30.0-beta.1/herdr_harness/README.md#update-the-server). Preserve private configuration, state, and the prior runtime for rollback. Install the matching CLIs and bundled Pi package, then restart the companion service only when you are ready for that explicit server cutover.

This package does not install itself. The Mac updater updates only the native Mac app and does not deploy or restart a companion server. Existing clients safely ignore the additive fields, while the 0.30.0 Mac preview requires this package for the new server, API, and CLI behaviors listed above. The wheel includes the updated First Mate browser UI. Matching iOS source changes are included in the repository, but no iOS binary is released here.

## Verification

1. Read the authenticated root capabilities and confirm `first-mate-usage-v1`, `chat-tab-colors-v1`, and `first-mate-archive-v1`. Then read `/api/v1/assistant/capabilities` and confirm `smart-rename-v1` plus Response Brief length policy version 2.
2. Inspect a synthetic First Mate task in the browser and native Mac app. Confirm usage coverage, archive/unarchive retention, and exclusion of archived features from active attention counts.
3. Run a synthetic tool-free Smart Rename request and all three Response Brief lengths. Confirm invalid inputs fail closed and replayed receipts do not duplicate work.
4. Enable tab-color sharing from a test Mac, compare filtered results from `herdr-control` and `herdr-hud-chats`, then disable sharing and confirm the exported copy is withdrawn.

## Tracking

- Smart Rename: [issue #22](https://github.com/ronnie3786/herdr-companion/issues/22), [PR #23](https://github.com/ronnie3786/herdr-companion/pull/23)
- Response Brief length and recovery: [issue #25](https://github.com/ronnie3786/herdr-companion/issues/25), [PR #26](https://github.com/ronnie3786/herdr-companion/pull/26)
- PR Review windows and diff styling: [issue #28](https://github.com/ronnie3786/herdr-companion/issues/28), [PR #29](https://github.com/ronnie3786/herdr-companion/pull/29)
- Tab-color discovery: [issue #27](https://github.com/ronnie3786/herdr-companion/issues/27), [PR #32](https://github.com/ronnie3786/herdr-companion/pull/32)
- First Mate archive: [issue #31](https://github.com/ronnie3786/herdr-companion/issues/31)

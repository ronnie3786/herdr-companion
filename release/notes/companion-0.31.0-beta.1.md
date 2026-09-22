# Companion 0.31.0b1

This companion package supplies the server, API, browser, and CLI support for Herdr Companion 0.31.0 Preview 1 on Mac. It combines role-based First Mate model routing and exact model attribution with the previously reviewed workflow improvements from [PR #34](https://github.com/ronnie3786/herdr-companion/pull/34).

## Changes

- **First Mate model routing and attribution:** private host defaults cover coordinator, planning, and execution models and thinking levels. Delegation selects a planning or execution profile, and configured role models take priority over legacy agent-supplied overrides. Feature-specific coordinator settings still apply to the next conversation turn. New dispatches, retries, and acknowledged handoff successors resolve the current policy; running workers retain their dispatch settings until completion or safe handoff. Additive selection metadata separates requested settings from actual values observed in Pi state and validated saved sessions. Unknown actual settings remain unknown. Normal Pi tools, skills, extensions, project context, workflow authorization, session ownership, and handoff acknowledgement checks remain available and enforced.
- **First Mate usage and cost:** additive `first-mate-usage-v1` responses report per-session, per-agent, child-tree, and whole-task model usage and Pi-estimated cost. Retained coordinator history, nested workers, retries, handoffs, and recovery advisors are counted once. Missing or partial coverage remains explicit, existing saved usage is collected without invoking a model, and estimates are not billing invoices.
- **Smart Rename:** `smart-rename-v1` enforces a one-shot, tool-free naming run with the requested model and thinking level on the target's owning companion. The profile never receives tools or topology data. Provider, validation, unsupported-model, and stale-target failures fail closed and cannot be mistaken for a successful rename.
- **Response Brief length:** `responseBriefs.lengthPolicyVersion` 2 advertises Minimal, Medium, and Long. Requests capture the chosen policy, legacy receipts remain replayable, and the server validates the additive `responseBriefLength` field without changing older clients' payload behavior. Mac-side identity validation and baseline recovery prevent unverified history matching and duplicate replacement submissions.
- **Read-only tab-color discovery:** `chat-tab-colors-v1` accepts authenticated, per-installation publications and exposes assigned, unassigned, unavailable, and stale discovery data. Updated `herdr-control` and `herdr-hud-chats` commands add color filters and grouping. Publication is off by default, agent-side color mutation is rejected, local state remains authoritative, and no client imports or synchronizes another client's values.
- **First Mate archive:** `first-mate-archive-v1` adds deterministic active, archived, and all views plus idempotent archive and unarchive actions. Archive remains independent of workflow state, preserves every feature record and link, allows running work to continue, and removes archived features from default lists and attention counts. Database migration is additive.
- **PR Review compatibility:** pop-out windows and enhanced native diff styling are Mac-only. Review hosts need only the existing `pr-review-v1` behavior; this package does not add a new PR Review API for those presentation changes.

## Installation and compatibility

Install the wheel in a new versioned Python 3.11+ environment and follow the [server update procedure](https://github.com/ronnie3786/herdr-companion/blob/companion-v0.31.0-beta.1/herdr_harness/README.md#update-the-server). Preserve private configuration, state, and the prior runtime for rollback. Install the matching CLIs and bundled Pi package, then restart the companion service only when you are ready for that explicit server cutover.

Configure coordinator and role defaults through the private `first_mate` settings described in [runtime configuration](https://github.com/ronnie3786/herdr-companion/blob/companion-v0.31.0-beta.1/docs/first-mate/runtime.md), using provider-qualified models available on that host. This release does not select or configure a paid provider or model.

This package does not install itself. The Mac updater updates only the native app and does not deploy, replace, or restart a companion server. Existing clients safely ignore additive fields, while [Herdr Companion 0.31.0 Preview 1 on Mac](https://github.com/ronnie3786/herdr-companion/releases/tag/macos-v0.31.0-beta.1) requires companion 0.31.0b1 for the new server, API, and CLI behaviors listed above. The wheel includes the updated First Mate browser UI. Matching iOS source changes are included in the repository, but no iOS binary is released here.

## Verification

1. Read the authenticated root capabilities and confirm `first-mate-usage-v1`, `chat-tab-colors-v1`, and `first-mate-archive-v1`. Then read `/api/v1/assistant/capabilities` and confirm `smart-rename-v1` plus Response Brief length policy version 2.
2. Open First Mate model settings, start new planning and execution dispatches, and inspect agent rows and saved sessions. Confirm role defaults are applied, requested settings remain distinct from observed actual values, and unavailable actual values remain unknown.
3. Inspect a synthetic First Mate task in the browser and native Mac app. Confirm usage coverage, archive/unarchive retention, and exclusion of archived features from active attention counts.
4. Run a synthetic tool-free Smart Rename request and all three Response Brief lengths. Confirm invalid inputs fail closed and replayed receipts do not duplicate work.
5. Enable tab-color sharing from a test Mac, compare filtered results from `herdr-control` and `herdr-hud-chats`, then disable sharing and confirm the exported copy is withdrawn.

## Tracking

- Smart Rename: [issue #22](https://github.com/ronnie3786/herdr-companion/issues/22)
- Response Brief length and recovery: [issue #25](https://github.com/ronnie3786/herdr-companion/issues/25)
- Tab-color discovery: [issue #27](https://github.com/ronnie3786/herdr-companion/issues/27)
- PR Review windows and diff styling: [issue #28](https://github.com/ronnie3786/herdr-companion/issues/28)
- First Mate archive: [issue #31](https://github.com/ronnie3786/herdr-companion/issues/31)
- Consolidated workflow delivery: [PR #34](https://github.com/ronnie3786/herdr-companion/pull/34)

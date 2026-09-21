# Next macOS update — unreleased

## Feedback

- Help → **Report a Bug or Request a Feature…** (⌘⌥F) and Settings → General → Feedback open a sheet that files through this Mac's companion, or the first connected companion, as a public GitHub issue with your verbatim description and up to six attachments. Included environment details are listed before sending and never contain machine names or hostnames.
- **Start the automated fix pipeline** labels the issue for the optional Code Factory daemon. Requires a companion server advertising `issue-reports-v1`; older servers show an update message.

## Sidebar and navigation

- Recents uses compact single-line titles, quieter machine/workspace context, and visible Working, Done, and attention states. Full tab context stays available on hover.
- Leaving Recents restores the ordinary grouped-row styling. Selected chats keep their background highlight without a leading vertical stripe.
- Sidebar titles and status read live pane data so Smart Rename and agent completion stay aligned with the chat header and HUD.
- Back and Forward remember Chat/Git segment switches on the same pane, including returning to Git after visiting another pane or screen.
- New workspace is a labeled sidebar action. Hover a machine row for a folder-plus button that opens creation directly on that machine, without another machine selection. Workspace headings in Unread and Starred expose the same right-click menu as the workspace tree, including New tab.
- Workspace folders are easier to pick out of the sidebar: 14-point semibold titles in the brighter text color, 14-point mist folder icons, and taller folder rows while tabs, chats, machines, and group labels keep their compact styling. Long names still truncate at the tail with their counts, chevrons, tooltips, and accessibility information intact. This visibility change needs no server update and adds no new setting.
- The computer segment bar now uses optional `sidebar_label` and `sidebar_order` values from the private machine roster instead of built-in name aliases. Ordered computers appear first; ties and computers without an order keep saved roster order. Missing labels show the full name, duplicate labels remain separate connections, and selection still uses the original paired machine ID. The authenticated companion identifies its own configured roster record for the already-saved first connection, so a localhost or other origin alias still receives the configured presentation; other paired computers continue to require unique exact-origin matches. Duplicate or unknown self IDs are never guessed. Zero machines remain hidden and four or more still use the full-name menu. Runtime updates require an updated companion and Mac app: restart the companion after editing the first saved connection's authoritative TOML, then Refresh or reconnect. Failed or unsupported metadata requests retain the cached presentation offline; URLs, credentials, roles, names, saved IDs, and saved connection order are unchanged.

## Chat and HUD

- Attachment chips remain compact and scroll horizontally instead of stretching the composer.
- Long prompt drafts scroll with the mouse or trackpad after reaching five visible lines. Existing Return and modified-Return behavior is retained.
- Grouped tool calls are labeled Clanking. Failures remain indicated in the collapsed header and no longer expand the group automatically.
- The HUD notes list starts as one Notes icon. Click to expand; click again to minimize. Creating or opening a note still opens its editable card.

## Response briefs

- **Length** is now one app-wide choice—**Minimal**, **Medium**, or **Long**—defaulting safely to Minimal, stored independently of per-chat opt-in, model, and thinking, and applied to future requests in every chat. For multiplier `m` (1, 2, or 3), total visible content is capped at `m * max(40, min(240, floor(readable characters / 4)))` non-whitespace scalars and `m *` the existing word ceiling—at most 40/240, 80/480, and 120/720 words/scalars. A short source's allowance is a maximum, not a minimum or a padding target.
- Changing Length regenerates the brief for the source currently selected in the rail, or the latest completed answer when none is selected; re-selecting the same value does nothing, and returning to a formerly used preset still creates a deliberate fresh generation. Accepted and transport-uncertain runs reconcile under their captured preset before a replacement starts, rapid changes coalesce to the latest selection, and a pending replacement resumes once after relaunch. Other chats and saved records are not regenerated.
- Completed answers with any non-whitespace text are now eligible, including one-character and emoji-only answers. Generated summaries have no minimum length and are never padded, repeated, or truncated; the old 160-readable-character skip and the 12–20-word guidance are removed.
- The saved-baseline warning is addressed for ordinary live-to-persisted refresh: an answer observed while live can persist under a different identifier, so the coordinator now reconciles exact identifiers, prior verified aliases, and verified identity evidence (exact content hash plus real completed-message timestamp corroborated by the user turn). Display text, ordering, labels, and screenshots never match responses on their own. When continuity genuinely cannot be proven, the warning stays and **Restart briefs from latest response** offers confirmed latest-only recovery that never backfills unmatched history. The report's screenshot shows the warning but does not establish which transition its session took.
- Each new record captures the preset and policy version it was generated under, so cached records are validated against their own policy. Legacy records and receipts decode unchanged and replay byte-identical payloads; the upgrade never submits a backfill or automatically replays paid work.

## PR Review

- A new **PR Review** section under First Mate in the left navigator (⌘8): paste a GitHub pull request link, choose which review, explainer-video and utility skills to run, and get a GitHub-style workspace prepared on the development-role companion: ranked files with a single-category filter, Hide viewed and a Guided reading order; a native diff with **Ask AI** on any selection; a context library for findings, reports, audio, video and links; Agents and Skills tabs; archive instead of delete.
- `herdr-pr-review` CLI and `pr-review.*` agent-control actions drive the same workspace. Requires companion 0.27.0b1 (`pr-review-v1`) on the review host.

## Companion compatibility

Configurable brief length is additive. The companion advertises `responseBriefs.lengthPolicyVersion` 2 with `lengthOptions`, and the Mac requires all three options before sending a new-policy request. Older clients that omit `responseBriefLength` keep the legacy prompt, budgets, and payloads byte-for-byte. A companion that only advertises `response-brief-v1` shows **Update the companion for configurable brief length…** with **Retry after updating**; the request is not sent, no generic-agent fallback is used, and existing accepted legacy runs remain reconcilable. Install and restart the updated companion separately on each machine where briefs are enabled: the Mac updater does not install or restart server packages, and **Reload brief support and models** rechecks the capability.

The configurable computer segments add optional presentation fields and a validated `localMachineId` to the authenticated machine-roster response. Existing clients ignore them. The Mac uses the self ID only for its already-saved first connection, including localhost or another origin alias; nonprimary machines still match by unique exact origin. Missing self identity preserves older-server origin fallback, while duplicate, unknown, or ambiguous claims are not guessed. The app never imports machines or credentials or rewrites saved identity. Both the companion and Mac app must be updated for self-identity synchronization, and a Mac-only update does not install companion code.

A separate companion update raises the shared headless-agent timeout, including HUD chat, from ten minutes to one hour by default. A Mac-only update does not change the running server's timeout. Existing explicit overrides remain effective; `HERDR_HARNESS_AGENT_TIMEOUT_SECONDS` supports 1–86,400 seconds through the private configuration's `[environment]` table. Cancellation remains available.

## Quick verification

1. Toggle Recents on and off; Smart Rename a chat and compare its sidebar/header title. Let a working agent finish and compare the sidebar with its HUD notification.
2. Switch Chat → Git → another pane; use Back twice and Forward twice.
3. Attach multiple images, enter a draft longer than five lines, and scroll inside the editor. Confirm Return sends and modified Return inserts a newline.
4. Open a conversation with a failed tool call: Clanking should remain collapsed and show the failure count.
5. Toggle Notes twice, create a note, and close its card. Use New workspace and right-click workspace headings to find New tab.
6. Narrow the sidebar and enlarge the text size: workspace folder titles should stay visibly larger and brighter than the tabs and chats beneath them, with long names truncating at the tail and their counts and chevrons still visible. No server update or new setting is needed.
7. In a synthetic private roster, give arbitrary computer names optional labels such as Build and Lab, include tied and missing orders, and save the first companion through a localhost URL while its configured roster URL uses a different HTTPS origin. Restart that companion, then Refresh the Mac app. Confirm the first connection receives its exact configured presentation, nonprimary computers match only their unique origins, explicit orders precede unordered machines, ties remain in saved order, unlabeled segments use full names, duplicate labels still select distinct machines, and saved IDs, URLs, names, and selection survive relaunch. Remove a field and Refresh to confirm it clears. A roster of four or more machines keeps the existing full-name menu.
8. Complete a short synthetic answer, let it persist, then refresh the conversation or relaunch the app: the answer generates one brief with no duplicate request and no saved-baseline warning.
9. Switch Length across Minimal, Medium, and Long for a selected prior brief and for a one-character answer. Confirm fresh requests target the exact source, tiny summaries stay valid and short without filler, re-selecting the current value does nothing, and the preset survives relaunch.
10. Against a companion without the length capability, change Length and confirm the upgrade notice with no request. After separately updating and restarting the companion, **Retry after updating** works and **Reload brief support and models** refreshes the control.
11. Review the wide rail, narrow sheet, and large-text render artifacts against the synthetic response-brief checklist. The delivery validator confirms those artifacts and the manual checklist; the required exact-SHA Verify workflow owns the authoritative automated matrix, and no local duplicate suite is needed.

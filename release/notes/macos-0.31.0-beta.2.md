# Herdr Companion 0.31.0 Preview 2

This preview combines role-based First Mate model routing and exact model attribution with the previously reviewed workflow improvements from [PR #34](https://github.com/ronnie3786/herdr-companion/pull/34), plus a browser correction for saved worker-session visibility.

## Highlights

- **First Mate model routing and attribution:** private host defaults can route coordinator, planning, and execution work to separate models and thinking levels. Agent rows and saved session history distinguish requested settings from the actual values observed in validated Pi state; values that cannot be observed remain unknown. New messages, retries, and acknowledged handoff successors use the current policy, while running dispatches keep their settings until they finish or complete a safe handoff. Normal Pi tools, project context, session ownership, and workflow authorization checks remain enforced.
- **First Mate browser session visibility:** saved worker sessions without a current assignment remain visible once under **Saved worker sessions**, while sessions linked to an assignment are not duplicated. Requested routing and observed actual routing remain distinct, and all displayed model and thinking values remain safely escaped.
- **First Mate usage and cost:** task rows, Overview, Agents, and saved session history show Pi-reported model, token, and estimated USD cost data. Totals include retained coordinator sessions, nested workers, retries, handoffs, and recovery advisors without counting a reused session twice. Missing or incomplete data stays marked unavailable or partial instead of appearing as zero, and estimates are not billing invoices.
- **Smart Rename:** pane, HUD, terminal, and tab-color-group naming can use a successfully submitted prompt before the reply arrives, or bounded terminal output and pane metadata when no readable Pi conversation exists. The configured Smart Rename model and thinking level run on the target's owning companion through the enforced tool-free `smart-rename-v1` profile. Unsupported models, invalid output, provider failures, and stale targets fail closed, preserve the existing name, and report an actionable error.
- **Response Brief length and recovery:** one app-wide Minimal, Medium, or Long setting controls future brief budgets. Changing it regenerates the selected source, durable in-flight intent survives relaunch without duplicate paid requests, tiny answers remain eligible without padding, and verified identity evidence reconciles live responses with persisted snapshots. A genuinely unmatched baseline keeps a warning and offers confirmed latest-only recovery.
- **PR Review windows and diffs:** active reviews and retained documents can open in separate, host-pinned windows while the main window remains usable. A removed host becomes unavailable instead of silently falling back to another host. Native diffs add full-width change backgrounds, darker gutters, and intraline emphasis. These presentation changes are Mac-only and require no new server behavior beyond the existing `pr-review-v1` support.
- **Read-only tab-color discovery:** the off-by-default **Share tab colors with companions** privacy setting publishes a read-only copy of this Mac's known tab colors and effective labels. Agents can filter and group them with the updated `herdr-control` and `herdr-hud-chats` CLIs. Local storage remains authoritative, other clients never import these values, and agent mutation stays disabled.
- **First Mate archive:** archive finished or irrelevant features without changing workflow status or deleting their conversation, agents, documents, sessions, journal, Active Work link, or work item identity. Running work continues, archived features leave the active list and attention count, and **Show archived** exposes Unarchive.

## Compatibility and installation

Use **Herdr Companion > Check for Updates...** to review and install the signed [macOS 0.31.0 Preview 2 release](https://github.com/ronnie3786/herdr-companion/releases/tag/macos-v0.31.0-beta.2).

The separately published [**companion 0.31.0b2** package](https://github.com/ronnie3786/herdr-companion/releases/tag/companion-v0.31.0-beta.2) is required on each relevant host for the browser correction, role routing and selection details, plus the new server, API, and CLI behavior: usage reporting, tool-free Smart Rename, configurable Response Brief length, tab-color discovery, and First Mate archive/unarchive. Update the companion wheel, matching CLIs, and bundled Pi package using the documented server update procedure, then restart that service when you are ready for the cutover. The Mac updater does not deploy, replace, or restart companion servers.

Configure role defaults privately on each host with provider-qualified models available there. This release does not select or configure a paid provider or model. Existing clients remain compatible with the additive APIs. The PR Review pop-out windows and diff styling are Mac-only once the review host supports `pr-review-v1`. Matching iOS source changes are included in the repository, but this release publishes no iOS binary.

## Quick verification

1. In the First Mate browser, confirm a saved worker session without a current assignment appears once under **Saved worker sessions**, while an assignment-linked session is not duplicated. Verify requested and observed routing labels remain distinct and escaped.
2. In First Mate, create a new planning or execution dispatch. Compare the requested role policy with the actual model and thinking level in the agent row and saved session, and confirm unknown actual values are not inferred.
3. Compare a task's sidebar cost with Overview, Agents, and saved sessions. Confirm incomplete usage coverage is labeled.
4. Smart Rename a newly submitted HUD chat before a reply arrives, then verify an unsupported model or older companion leaves the title unchanged with update guidance.
5. Generate the same synthetic Response Brief at Minimal, Medium, and Long. Relaunch during a replacement and confirm exactly one authorized result resumes. Use latest-only recovery only for a deliberately unmatched baseline.
6. Pop out two PR Reviews, navigate the main window independently, and confirm each review remains pinned to its original host and keeps the enhanced diff styling.
7. With agent control off, enable tab-color sharing, compare color-label results from both updated CLIs, then disable sharing and confirm the published copy is withdrawn while local colors remain.
8. Archive a running synthetic First Mate feature, confirm work continues and its attention count disappears, then show archived features and unarchive it without changing its workflow status.

## Tracking

- Smart Rename: [issue #22](https://github.com/ronnie3786/herdr-companion/issues/22)
- Response Brief length and recovery: [issue #25](https://github.com/ronnie3786/herdr-companion/issues/25)
- Tab-color discovery: [issue #27](https://github.com/ronnie3786/herdr-companion/issues/27)
- PR Review windows and diff styling: [issue #28](https://github.com/ronnie3786/herdr-companion/issues/28)
- First Mate archive: [issue #31](https://github.com/ronnie3786/herdr-companion/issues/31)
- Consolidated workflow delivery: [PR #34](https://github.com/ronnie3786/herdr-companion/pull/34)

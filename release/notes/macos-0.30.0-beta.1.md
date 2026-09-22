# Herdr Companion 0.30.0 Preview 1

This preview combines First Mate usage reporting with five completed workflow improvements.

## Highlights

- **First Mate usage and cost:** task rows, Overview, Agents, and saved session history show Pi-reported model, token, and estimated USD cost data. Totals include retained coordinator sessions, nested workers, retries, handoffs, and recovery advisors without counting a reused session twice. Missing or incomplete data stays marked unavailable or partial instead of appearing as zero.
- **Smart Rename:** pane, HUD, terminal, and tab-color-group naming can use a successfully submitted prompt before the reply arrives, or bounded terminal output and pane metadata when no readable Pi conversation exists. The configured Smart Rename model and thinking level run on the target's owning companion through the enforced tool-free `smart-rename-v1` profile. Unsupported models, invalid output, provider failures, and stale targets preserve the existing name and report an actionable error.
- **Response Brief length and recovery:** one app-wide Minimal, Medium, or Long setting controls future brief budgets. Changing it regenerates the selected source, durable in-flight intent survives relaunch without duplicate paid requests, tiny answers remain eligible without padding, and verified identity evidence reconciles live responses with persisted snapshots. A genuinely unmatched baseline keeps a warning and offers confirmed latest-only recovery.
- **PR Review windows and diffs:** active reviews and retained documents can open in separate, host-pinned windows while the main window remains usable. Native diffs add full-width change backgrounds, darker gutters, and intraline emphasis. These presentation changes are Mac-only and require no new server behavior beyond the existing `pr-review-v1` support.
- **Read-only tab-color discovery:** the off-by-default **Share tab colors with companions** privacy setting publishes a read-only copy of this Mac's known tab colors and effective labels. Agents can filter and group them with the updated `herdr-control` and `herdr-hud-chats` CLIs. Local storage remains authoritative, other clients never import these values, and agent mutation stays disabled.
- **First Mate archive:** archive finished or irrelevant features without changing workflow status or deleting their conversation, agents, documents, sessions, journal, Active Work link, or work item identity. Running work continues, archived features leave the active list and attention count, and **Show archived** exposes Unarchive.

## Compatibility and installation

Use **Herdr Companion > Check for Updates...** to review and install this signed Mac preview.

The separately published **companion 0.30.0b1** package is required on each relevant host for the new server, API, and CLI behavior: usage reporting, tool-free Smart Rename, configurable Response Brief length, tab-color discovery, and First Mate archive/unarchive. Update the companion wheel, matching CLIs, and bundled Pi package using the documented server update procedure, then restart that service when you are ready for the cutover. The Mac updater does not deploy, replace, or restart companion servers.

The PR Review pop-out windows and diff styling are Mac-only once the review host already supports `pr-review-v1`. The repository also includes matching iOS source updates for First Mate archive behavior, but this release publishes no iOS binary.

## Quick verification

1. In First Mate, compare a task's sidebar cost with Overview, Agents, and saved sessions. Confirm incomplete coverage is labeled.
2. Smart Rename a newly submitted HUD chat before a reply arrives, then verify an unsupported model or older companion leaves the title unchanged with update guidance.
3. Generate the same synthetic Response Brief at Minimal, Medium, and Long. Relaunch during a replacement and confirm exactly one authorized result resumes. Use the latest-only recovery only for a deliberately unmatched baseline.
4. Pop out two PR Reviews, navigate the main window independently, and confirm each review remains pinned to its original host and keeps the enhanced diff styling.
5. With agent control off, enable tab-color sharing, compare color-label results from both updated CLIs, then disable sharing and confirm the published copy is withdrawn while local colors remain.
6. Archive a running synthetic First Mate feature, confirm work continues and its attention count disappears, then show archived features and unarchive it without changing its workflow status.

## Tracking

- Smart Rename: [issue #22](https://github.com/ronnie3786/herdr-companion/issues/22), [PR #23](https://github.com/ronnie3786/herdr-companion/pull/23)
- Response Brief length and recovery: [issue #25](https://github.com/ronnie3786/herdr-companion/issues/25), [PR #26](https://github.com/ronnie3786/herdr-companion/pull/26)
- PR Review windows and diff styling: [issue #28](https://github.com/ronnie3786/herdr-companion/issues/28), [PR #29](https://github.com/ronnie3786/herdr-companion/pull/29)
- Tab-color discovery: [issue #27](https://github.com/ronnie3786/herdr-companion/issues/27), [PR #32](https://github.com/ronnie3786/herdr-companion/pull/32)
- First Mate archive: [issue #31](https://github.com/ronnie3786/herdr-companion/issues/31)

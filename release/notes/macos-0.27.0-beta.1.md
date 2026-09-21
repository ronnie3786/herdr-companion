# macOS 0.27.0-beta.1

## PR Review workspace

Delivered in [#24](https://github.com/ronnie3786/herdr-companion/pull/24).

- A new **PR Review** section sits in the main toolbar picker (View → PR Review, ⌘8), separate from Active Work. Paste a GitHub pull request link into the sidebar field to start a review; a sheet lets you choose which review, explainer-video, and utility skills to run right away, or add the review without running anything.
- Reviews are prepared on the machine whose configured role is `development` (or the host chosen in Settings → Machines → **PR review host**): the companion fetches the PR with `gh`, checks the head out into a per-review worktree, parses the diff, opens a tab in the dedicated **PR Reviews** Herdr workspace, and pulls your GitHub viewed-file state.
- The **Files** tab lists changed files ranked by AI impact (High, Medium, Low, Unranked) with a one-line reason each, a single-category filter, a **Hide viewed** toggle, and a **Guided** order that lists files in the order the AI recommends for building a mental model. Each file has a viewed checkbox (⌥V) that also updates GitHub when enabled.
- The native diff viewer shows every hunk with old/new line numbers and full-width add/remove tinting. ⌥↑ / ⌥↓ move between files.
- **Context** holds the review library: per-agent markdown findings, the consolidated HTML report, audio summaries, explainer videos, links, and anything you drop in (files, folders, or web links). Markdown and HTML open inside the app; audio and video download once and open in QuickTime Player.
- **Agents** lists every skill run with its state, pane, and latest output; open the pane in Herdr, or finish or fail a run by hand. **Skills** shows which skills have run, lets you mark them ran or not run, run any of them again, and add custom skills without an app update.
- Reviews are archived, never deleted. The Archived filter keeps old reviews and all their documents, runs, and findings reachable.

## Ask AI about the code

- Select code in the diff and choose **Ask AI** (floating button or right-click). The question carries the file, line range, before/after side, the exact selection, surrounding lines, the PR summary, and the agents' findings for that file as reference only.
- Answers come from a new `pr-review-question-v1` profile that runs on the review host with read-only tools inside the PR checkout, so it can verify findings by reading the code instead of repeating them. Continue in an agent when you want actions.

## Agent-driven review control

- `herdr-pr-review` creates reviews, starts and finishes skill runs, marks skills, sets rankings and viewed state, adds documents and links, archives, and opens a review at a file and line through a `herdr://pr-review` link.
- Agent control gains the `pr-review` segment and `pr-review.*` UI actions (open, select file, scroll to line, highlight lines, set filter, view mode, tab, viewed state, and a `state` read) so an external tutor such as Clicky can drive and read the view. See [docs/pr-review.md](https://github.com/ronnie3786/herdr-companion/blob/main/docs/pr-review.md).

## Compatibility

This release updates the Mac app only. PR Review requires companion 0.27.0b1 or newer on the review host, which advertises `pr-review-v1` and the `pr-review-question-v1` question profile, with `gh` authenticated and the review skills installed on that machine. Older servers show an update message in the PR Review section; every other feature is unchanged and needs no server update.

## Quick verification

1. Launch with `-HerdrDemoMode`, press ⌘8, and confirm the demo review lists ranked files, a guided order, documents, runs, and skills.
2. On a live setup, paste a PR link, choose one review skill, and watch the run appear under Agents and its findings under Context.
3. Filter Files to High, toggle Hide viewed, mark a file viewed with ⌥V, and check the box on GitHub.
4. Select a few lines in the diff, choose Ask AI, and confirm the question window shows the file, lines, and side in its context.
5. Run `herdr-pr-review list` and `herdr-control … ui segment pr-review` against the review host.

Install through **Herdr Companion → Check for Updates…** with preview builds enabled.

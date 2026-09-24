# PR Review

Status: macOS 0.40.0-beta.1 with companion 0.40.0b1 (2026-09-23).
Product intent lives in [pr-review-assistant.md](pr-review-assistant.md).

PR Review turns a GitHub pull request link into an AI-assisted review workspace inside the
Mac app. The review itself, its skill runs, its documents and its findings live on the
**review host**: the companion whose configured machine role is `development`. The Mac app is a
client of that companion. Nothing in a review is ever deleted; finished reviews are archived.

## Setup

On the review host:

1. Install companion 0.27.0b1 or newer. `GET /api/v1` advertises `pr-review-v1` and the
   `pr-review-question-v1` question profile.
2. Authenticate `gh` for the GitHub account that can read the pull requests you review, and
   install the `gh autoview` extension if you use the mark-viewed utility.
3. Install the review skills for the agent runner (`pi` by default) so these names
   resolve: `ios-review-remote-pr`, `comprehensive-pr-review`, `github-pr-explainer-video`,
   `github-pr-explainer-video-v2`, `tech-explainer-video`, `pr-explainer-dev-manager`,
   `mark-generated-and-test-viewed-in-pull-request`. Pi discovers shared skills in
   `~/.agents/skills/` and invokes them with `/skill:<name>`. Selected skills use
   the host's existing global Pi provider and model settings. Install selected
   skills globally: managed review runs ignore checkout-local Pi settings,
   extensions, and skills, so reviewing a new checkout does not require granting
   it project trust.
4. Optionally add a `[pr_review]` table to the private configuration
   (see [config.example.toml](../config.example.toml)). Every key has a default:

| Key | Default | Purpose |
| --- | --- | --- |
| `workspace_label` | `PR Reviews` | The dedicated Herdr workspace that holds one tab per review. |
| `workspace_root` | server home | Working directory used when that workspace has to be created. |
| `checkout_root` | `<state_dir>/pr-review-runs/checkouts` | Shared repository clones plus one worktree per review. |
| `store_path` | `<state_dir>/pr-review.sqlite3` | SQLite ledger of reviews, files, runs, marks, documents, events. |
| `runs_root` | `<state_dir>/pr-review-runs` | Per-review private files: PR metadata, diff, documents, run logs. |
| `runner` | `pi` | Agent launched for skill runs. An explicitly configured `claude` runner remains supported. |
| `model`, `thinking_level` | Pi default, `medium` | Model used for impact ranking and Ask AI answers. |
| `auto_rank` | `true` | Rank files automatically after a review is prepared. |
| `sync_viewed_to_github` | `true` | Push viewed toggles to GitHub through the GraphQL API. |
| `gh_timeout_seconds` | `120` | Timeout for GitHub metadata and API calls (10–900). |
| `checkout_timeout_seconds` | `900` | Timeout for each clone, fetch, and checkout command (10–3600). Clones fetch blobs on demand and skip checking out the default branch. |
| `pi_binary`, `claude_binary` | found on `PATH` | Explicit binaries when the service PATH differs. |

Local comments require no additional capability: the Mac stores them privately using the review and diff data already returned by `pr-review-v1`. There is no comment endpoint, no comment text is sent to the companion, and the `herdr-pr-review` CLI is unchanged.

On the Mac: pair the review host in Settings → Machines as usual. The app picks the machine
whose role is `development`; Settings → Machines → **PR review host** overrides that choice.
Demo mode (`-HerdrDemoMode`) shows a synthetic review without any server.

## Using it

Open **PR Review** from the left navigator (directly under First Mate) or press ⌘8. The left
column becomes the review rail: the review host, a field for a GitHub pull request link,
Active / Archived, search, and the reviews themselves.

**Starting a review.** Paste a link such as `https://github.com/example-owner/example-repo/pull/42`
and press Return. A sheet lists the review skills, explainer-video skills, utilities and custom
skills; choose which to run now (the last selection is remembered) or add the review without
running anything. The companion then fetches the PR with `gh`, clones the repository once and
checks the head out into a per-review worktree, parses the diff, opens a tab named
`PR #42 · <title>` in the PR Reviews workspace, pulls your GitHub viewed-file state, marks the
review ready, starts the chosen skills, and ranks the files. Creating the same open PR twice
returns the existing review.

Starting with companion 0.27.0b2, if the companion restarts during preparation, it resumes active, unfinished preparation
with the original queued skill runs. A persisted review tab is reused. Completed, failed,
and archived reviews are not automatically prepared again. Failed preparation identifies
the failed stage; use **Refresh** to retry with the original queued skills. Timed-out
commands stop their whole process group so Git children cannot keep writing after failure.
On older companions, submitting the same PR with **Add without running** resumes interrupted preparation without adding
new runs; it keeps the original skill selection.

Companion 0.27.0b2 also defaults skill runs to Pi. Existing stored slash-command
templates are translated to Pi's `/skill:<name>` syntax at launch, including queued
runs created by older companions. Freeform prompts remain unchanged.

Starting with companion 0.27.0b3, Pi runs use `--no-approve` to continue with global
resources without a project-trust prompt. An idle agent pane is not evidence that
the skill completed; automatic completion requires the terminal's explicit `done`
status. You can still finish a run manually from Agents.

**Files.** Files carry an AI impact (High, Medium, Low, or unranked). A short **Why** explanation above the diff describes what deserves attention or why the change is routine, in both GitHub and Guided order. Missing explanations are called out rather than inventing a safety claim; use **Rank files** to generate them. The filter controls stay at the top even when no files match.
Filter to one impact at a time, hide viewed files, search, and switch between GitHub order and
the **Guided** order, which lists files in the order the AI suggests for building a mental model
and explains each position above the diff. ⌥↑ and ⌥↓ move between files; ⌥V or the checkbox
marks a file viewed (also on GitHub when syncing is enabled). **Rank files** re-runs the ranking;
`herdr-pr-review set-rankings` lets an agent supply its own.

**Diff and Ask AI.** PR Review, Chat Git and First Mate Git use one shared code renderer and theme: syntax-highlighted code, roomier lines, old/new line numbers, full-width green/red row tints, stronger gutters and changed-word emphasis. The PR Review renderer is bundled in the Mac app; rendering a loaded patch does not fetch scripts, fonts or grammars from the network. Review-specific selection and navigation are adapters around that renderer; the existing Git workbench retains its split/unified and wrap controls.
Deleted text files carry a textual **Deleted** label in the file rail and the selected-file header and start collapsed. The selected file shows its path and a compact removal summary with a **Show deleted content** control instead of its removed lines; **Show deleted content** mounts the shared renderer for the available removal hunks, and **Hide deleted content** unmounts it again. The choice is per file and held in memory for the current host, review, base SHA and head SHA in each window: it survives file navigation, viewed updates and unchanged polling, and resets for another host, review, revision, a newly opened window, or an app relaunch. It never syncs between clients and is independent between the main window and pop-outs. A modified file that only removes lines stays expanded normally; deletion is always the companion's explicit `deleted` status, never a removal count or an all-red hunk. A deleted binary or hunk-less diff keeps its honest message instead of offering a control with no effect. Long files scroll vertically
and horizontally, and the selected-file action row wraps onto another line when enlarged text or a minimum-size window would otherwise crowd it. If the patch is truncated, Herdr shows every available hunk with a partial-diff
notice and a link to the full diff; a deleted file keeps that notice and link available while its content is hidden. An explicit line-navigation or highlight request for a collapsed deleted file reveals its content so the requested line is reachable, while hiding drops its reported visible lines and a stale request never reopens what was hidden manually. While an Ask AI selection draft is nonempty, hiding is unavailable so the draft cannot be discarded, and the control is focusable and announces its **Expanded** or **Collapsed** state to keyboard and VoiceOver users. Disclosure is presentation-only: it never marks a file viewed, submits a question, alters the patch, or changes the review. Select code and choose **Ask AI** (floating button or right-click).
The question carries the file, the exact selection, whether it is on the before or after side,
the line range, up to 40 surrounding lines, the PR summary, and the review agents' findings for
that file as reference only. Answers come from the `pr-review-question-v1` profile: a Pi run
started in the review's checkout with only `read`, `grep`, `find` and `ls`, and a charter that
tells it to verify findings by reading the code rather than repeating them. Scoping is the
working directory plus the charter; it is not a sandbox. Follow-ups continue the same
conversation; **Continue in agent** hands off for actions. The system prompt requests the **short version** unless you ask for a long answer or more details (requires companion 0.40.0b1).

New questions stay as **Saved questions** bubbles below the diff. Click a bubble to reopen its saved conversation without sending the question again. Each new selection question starts a separate thread, and follow-ups stay in that thread. Bubbles survive file switches, review refreshes, pop-out closure and app relaunch. They are scoped to the original host/review, carry file and line context, and show **Earlier revision** after the PR changes. The index and transcripts are stored privately on this Mac; they do not sync to other clients. Questions created before this version are not retroactively indexed. A saved thread is not cleared by starting another question.

**Local comments.** Select code and choose **Add comment** beside **Ask AI** (or keep using right-click for the Ask AI question field). The local editor freezes the file, before/after side, line ranges, exact selected code, and the review's `base`/`head` SHAs at the moment it opens, so one selection may cross added, removed and context lines. Save requires nonblank text and stores the Markdown exactly as typed — internal blank lines, trailing spaces and non-ASCII characters are preserved. Cancel creates no record; a blank Save is refused; a failed write keeps the draft in the editor with its reason and never reports success.

Saved comments are private JSON under the app's Application Support directory (`Herdr/PRReview/pr-review-comments-v1.json`), written atomically with owner-only permissions. They are scoped by configured machine and review id — never by a display name or pull request number — so two hosts that reuse a review id or number stay separate. The main window and every popped-out review window share one process-wide store, so a comment saved in either appears in both, while the list itself remains scoped to the review it belongs to. Nothing is synchronized to the companion or another client, and comments are never pruned by refresh, archiving or window closure. Deleting that one file removes them; an unreadable, corrupt, or newer-version file is preserved and refuses writes until the operator resolves it.

The review header's **Comments** count and button are available on every tab, filter and empty state. The list shows each comment's compact saved code excerpt (with **Show full selection** when it exceeds three lines), its file and before/after line metadata, the exact text, and an **Earlier revision** or **Not in current revision** badge when applicable. **Show in diff** verifies the revision, clears the impact, viewed and text filters, switches to Files, selects the saved file and highlights the first saved span; it refuses to guess when the file, lines or revision no longer match. **Edit** updates the saved text in place. **Copy comment** copies only the exact comment Markdown, and **Open file in GitHub** opens that file's place in the pull request's **Files changed** view (`/pull/<n>/files#diff-<sha256 of the file path>`); for a saved commit, **Open original revision** opens the recorded file at that revision. Herdr never submits a comment or a review, never marks a comment published, and never puts comment text into a URL. To publish, copy the comment and paste it into GitHub manually.

After a refresh that changes the base or head, comments are not remapped onto the new diff. They keep their saved excerpt and an explicit **Earlier revision** label, and **Show in diff** explains why it will not highlight guessed current lines. A file or line that no longer exists in the loaded revision is reported instead of substituted.

**Refresh.** Companion 0.40.0b1 coalesces overlapping refreshes, fetches rebased PR heads, and publishes revision metadata and files together. Failed refreshes retain the last usable review with a retryable warning. Optional GitHub viewed-file sync cannot make a prepared review fail. Tracked edits in the managed checkout are preserved and block checkout replacement rather than being overwritten. New revisions invalidate old impact rankings and reset viewed state for changed patches; unchanged files keep their local marks. Old ranking jobs cannot overwrite ratings for a newer revision. The Mac keeps the file selection and filters when still applicable and keeps saved questions and saved comments anchored to their original revision. A saved comment from before the change stays readable with its **Earlier revision** excerpt and is never silently moved onto current code. Install the companion package separately on the review host; the Mac updater does not deploy it.

**Context.** The review library holds per-agent markdown findings, the consolidated HTML
report, audio summaries, explainer videos, links and anything you drop in (files, folders, web
links; uploads are limited to 20 MB, larger files are registered by path on the review host or
added as links). Markdown and HTML open inside the app; audio and video download once and open
in QuickTime Player; links open in the browser. Markdown and HTML document windows are pinned to
the review host that opened them: a credential or URL edit for that same machine reconnects them,
a removed host shows an unavailable state instead of falling back, and while one is open the
Context row reports Ready and offers Reveal in Finder. Skill runs register their outputs automatically.

**Agents.** Every skill run is a pane in the review's tab on the review host. The tab shows
the run state, the pane, its latest output, and buttons to open the pane, finish the run or mark
it failed, plus the review's event timeline. A run finishes when the agent or the CLI says so,
when the terminal reports the agent done, or is marked ended when its pane disappears.

**Skills.** Built-in skills are grouped by kind with their ran / not-run state and run history.
Mark a skill as ran or not run by hand, run it again, or add a custom skill (id, title, prompt
template with `{number}`, `{url}`, `{owner}`, `{repo}`, `{review_id}`, `{run_id}`, `{checkout}`
placeholders, output globs) without updating the app. Custom skills can also be added from the CLI.

**Archive.** Archiving hides a review from the Active list and keeps every file, run, document
and event; Archived lists them and Unarchive brings one back.

**Pop-out windows.** Right-click any active review row — selected or not — or the header of the
review currently displayed, and choose **Pop Out into Window**. The review opens in its own
resizable Mac window that keeps the complete workspace (Files, Context, Agents, Skills, and
Ask AI) while the main Herdr window stays free to move through All sessions and other chats;
an unsent chat draft is untouched by either window, and ⌘8 brings the section back. Every window
is pinned to the machine and review it was opened from: changing the main window's review host,
selection, or file never retargets it, and its Ask AI questions, document downloads, and agent
handoffs stay on that host. One window exists per machine/review pair, so reopening the same
review focuses its window instead of creating a duplicate; opening another review never replaces
an existing window. Closing a window only closes the view — the review, its files, runs and
documents stay on the review host and it remains in the Active list. A review whose host is
removed or unconfigured shows an unavailable message rather than silently falling back to another
machine. Titles, display labels, and pull request numbers are presentation; windows are identified
by machine and review id, so identical labels and duplicate numbers remain separate windows.
Pop-outs are Mac-side secondary windows, not separate processes, and need no server support
beyond the existing `pr-review-v1` capability. The review-wide comment list and its saved records
are shared by the main window and every popped-out window: a comment saved in one appears in the
other, and each window's list still shows only its own machine/review scope.

## Command line: `herdr-pr-review`

Installed with the companion wheel, using the same private `--config` and `--machine`
selection as `herdr-first-mate`. Output is JSON; errors are JSON on stderr with exit 4 for
conflicts and 2 otherwise. Mutations take `--request-id` for safe retries. Inside a review pane
the environment provides `HERDR_PR_REVIEW_ID` and `HERDR_PR_REVIEW_RUN_ID`, which the CLI uses
as defaults for `ID` and `RUN_ID`.

```sh
herdr-pr-review capabilities
herdr-pr-review list [--archived | --all]
herdr-pr-review create --url https://github.com/example-owner/example-repo/pull/42 --skill ios-review-remote-pr
herdr-pr-review get REVIEW_ID
herdr-pr-review files REVIEW_ID
herdr-pr-review diff REVIEW_ID [--path Sources/Example.swift]
herdr-pr-review file REVIEW_ID --path Sources/Example.swift --side after --start 40 --end 80
herdr-pr-review findings REVIEW_ID --path Sources/Example.swift
herdr-pr-review run REVIEW_ID --skill comprehensive-pr-review
herdr-pr-review runs REVIEW_ID
herdr-pr-review run-output REVIEW_ID RUN_ID --lines 200
herdr-pr-review finish-run [REVIEW_ID] [RUN_ID] --state finished --note "report written"
herdr-pr-review mark REVIEW_ID --skill tech-explainer-video --state ran
herdr-pr-review rank REVIEW_ID
herdr-pr-review set-rankings REVIEW_ID --file rankings.json   # or --file - for stdin
herdr-pr-review viewed REVIEW_ID --path Sources/Example.swift [--unviewed] [--no-github]
herdr-pr-review sync-viewed REVIEW_ID
herdr-pr-review documents REVIEW_ID
herdr-pr-review add-document REVIEW_ID --file /absolute/path/on/the/review/host.md --title "Findings"
herdr-pr-review add-document REVIEW_ID --upload ./report.html
herdr-pr-review add-document REVIEW_ID --link https://example.invalid/video --title "Explainer"
herdr-pr-review document REVIEW_ID DOCUMENT_ID --out ./report.html
herdr-pr-review events REVIEW_ID --after 0
herdr-pr-review archive REVIEW_ID | unarchive REVIEW_ID | refresh REVIEW_ID
herdr-pr-review skills | add-skill --id a11y-sweep --title "Accessibility sweep" | remove-skill a11y-sweep
herdr-pr-review open REVIEW_ID [--file PATH --line 42 --side after] [--tab files|context|agents|skills] [--print-url]
herdr-pr-review state [--client UI_ID] [--wait 30]
```

`set-rankings` reads a JSON array of `{"path", "impact": "low|medium|high", "reason",
"guided_order", "guided_reason"}`. `open` verifies the review and then opens a
`herdr://pr-review?...` link in the installed Mac app; links never carry tokens. `state` reaches
the Mac app through the agent-control receiver and returns the `pr-review.state` result below.

## Driving the view from outside (agent control, Clicky)

The Mac registers a `pr-review` segment and these UI actions with the agent-control receiver
(see [agent-control.md](agent-control.md)). All take parameters rather than targets.

| Action | Parameters | Effect |
| --- | --- | --- |
| `pr-review.open` | `review_id`, `tab?` | Opens the review (verifies it exists first). |
| `pr-review.select-file` | `path` | Selects a file in the Files tab. |
| `pr-review.scroll-to-line` | `path`, `line`, `side?` | Scrolls the diff so the line is visible and flashes it. |
| `pr-review.highlight-lines` | `path`, `start`, `end`, `side?` | Draws a ring around the lines. |
| `pr-review.clear-highlight` | — | Removes the ring. |
| `pr-review.set-filter` | `impact` (`all`, `high`, `medium`, `low`, `unranked`) | Impact filter. |
| `pr-review.set-view-mode` | `mode` (`github`, `guided`) | File order. |
| `pr-review.set-tab` | `tab` (`files`, `context`, `agents`, `skills`) | Switches tabs. |
| `pr-review.set-viewed` | `path`, `viewed` | Toggles viewed state. |
| `pr-review.state` | — | Returns the open review, tab, filter, view mode, selected file, visible line range, highlight, files with impact / guided order / viewed, runs and documents. |

```sh
herdr-control --control-machine desktop ui segment pr-review --wait 30
herdr-control --control-machine desktop ui invoke pr-review.scroll-to-line \
  --parameters-file scroll.json --wait 30      # {"path": "Sources/Example.swift", "line": 42, "side": "after"}
herdr-control --control-machine desktop ui invoke pr-review.state --wait 30
```

A tutor such as Clicky answers a spoken question by reading `pr-review.state`, fetching the
diff or findings through `herdr-pr-review`, then calling `select-file`, `scroll-to-line` and
`highlight-lines` while it speaks. Navigation actions are refused while a sheet or an unsent
Ask AI draft is open, so nothing the reviewer typed is lost.

## Shared renderer maintenance

The shared renderer lives in `frontend/herdr-web/src/components/Git/SharedDiffRenderer.tsx`.
Chat and First Mate use it through `DiffInspector`; PR Review supplies a structured patch through
its local WebKit adapter. After changing the renderer, theme, or native bridge page, run
`npm --prefix frontend/herdr-web run build:mac-diff` and commit the regenerated Mac resources.
The frontend tests rebuild into a temporary directory and compare the bundled renderer assets and license notices byte
for byte, so an improvement cannot silently ship to only one surface.

## Verification

- Python: `.venv/bin/python -m unittest tests.test_pr_review_store tests.test_pr_review_runtime tests.test_pr_review_http tests.test_pr_review_cli tests.test_pr_review_questions tests.test_pr_review_diff`.
- Mac unit (required exact-SHA Verify): `xcodebuild … test -only-testing:herdr-harness-macTests/PRReview*`.
  That suite covers the client contract, store and window scoping, routing identity, saved
  question persistence, refresh presentation, deleted-file disclosure and renderer mounting,
  the local WebKit renderer and synthetic demo layouts.
- Mac interactive (final gate): `xcodebuild -project herdr-harness-mac/herdr-harness-mac.xcodeproj -scheme herdr-harness-mac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:herdr-harness-macUITests/HerdrPRReviewUITests -only-testing:herdr-harness-macUITests/HerdrPRReviewCommentUITests`.
  That suite exercises the row and header context menus, two concurrent review windows with
  independent tabs and files, chat navigation with an unsent draft, duplicate-window focus, and
  close-versus-archive. Deleted-file coverage selects the synthetic deleted source, prose and
  long-path fixtures, verifies the textual Deleted label and the collapsed default with no mounted
  renderer, expands and collapses the removal hunks through Show/Hide deleted content, checks
  keyboard navigation and independent main/pop-out choices, and proves a nonempty Ask AI draft
  blocks collapse. It is recorded as pending until the final gate executes it; generated
  render PNGs and screenshots are layout evidence, not installed-app verification.
  `HerdrPRReviewCommentUITests` drives real diff selection and the bundled
  renderer's **Add comment** action against a unique temporary comment store: multiline Save,
  list preview and exact **Copy comment** text, **Edit**, **Show in diff** after obstructive
  filters, shared main/pop-out records, another review's isolation, and reopening after app
  termination on the same store. It never activates **Open file in GitHub**. Both suites are
  recorded as pending until the final gate executes them; generated render PNGs and screenshots
  are layout evidence, not installed-app verification. The manual GitHub link check below is the
  only browser evidence for file anchoring.
- Manual: [MANUAL_TEST_CHECKLIST.md](../herdr-harness-mac/MANUAL_TEST_CHECKLIST.md) → PR Review,
  including the production Git renderer comparison and simultaneous review/chat windows.

## Limits

- Uploads from the Mac are base64 JSON and capped at 20 MB; register larger files by path on
  the review host or add links.
- Run completion is a heuristic for interactive agents: the terminal's agent status, an explicit
  `finish-run`, or the pane closing. Output documents are registered while a run is running and
  once more when it finishes.
- The Ask AI profile restricts tools to read-only built-ins inside the checkout by working
  directory and charter; it is not an operating-system sandbox.
- Viewed sync needs the PR node id from `gh pr view`; a failed GitHub mutation is recorded as an
  event and never blocks the local toggle.
- Reviews of the same PR are keyed by repository and number while active; archive one to start
  a fresh review of the same PR.
- Pop-out windows are secondary Mac windows inside the same process, not separate launches.
  They share the app's credentials and reuse the machine/review-scoped PR Review endpoints, so
  they add no server capability beyond `pr-review-v1`.
- Deleted-file disclosure is window-local, in-memory presentation. It survives file navigation and
  unchanged refreshes in the same window, but resets for another host, review, base/head revision,
  a newly opened window, or an app relaunch; it is never synchronized and never changes viewed
  state or the patch. No companion support beyond `pr-review-v1` is required.
- Local comments are Mac-only and manual-publish only. There is no companion endpoint, no GitHub
  API call, no publication status and no cross-client synchronization; the only outbound actions
  are an explicit **Copy comment** and an explicit **Open file in GitHub** browser navigation.
- Comment anchors are frozen at composition. A rebased, force-pushed or otherwise changed revision
  shows **Earlier revision** with the saved excerpt rather than remapping to current lines; a file
  or line missing from the loaded diff is reported, never guessed. Comment storage is one
  versioned JSON file, replaced atomically; a corrupt, unreadable or unknown-version file is kept
  byte-for-byte and blocks writes until it is resolved.

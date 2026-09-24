# Herdr Mac manual test checklist

Use your configured Herdr Mac build with sample sessions. Check off each item after trying it.

## First Mate archive

- [ ] Right-click an inactive feature in the First Mate sidebar and choose **Archive…**. Leave the reason at **No reason** and confirm. The dialog must say records are retained; the feature leaves the default list without changing its workflow status.
- [ ] Archive a synthetic running feature. The confirmation must explicitly say work continues. Verify its assignments continue, then enable **Show archived**, inspect the conversation, journal, documents, sessions, status, Active Work linkage, and work item ID, and choose the visible **Unarchive** control.
- [ ] Repeat with each optional reason. Archived features must not contribute the First Mate attention badge, including `awaiting_direction` and `blocked` features. An older companion without `first-mate-archive-v1` must leave archive controls unavailable with update guidance.

- [ ] **Attachment titles on hover:** Have a session return several documents. At rest they should be icons. Hover the orb or any visible HUD control: all visible document titles should expand beside that session. Move between titles and click one, then move away to restore icons.

- [ ] **Documents belong to responses:** Have the same agent return different documents in two replies. Open Chat: each card should sit beneath the reply that produced it. Switch sessions and reopen an older chat to check that cards stay with the correct response.

- [ ] **Unavailable documents:** Try an expired result file or a known deleted document link. Expect a clear alert. An offline source Mac should show a connection message; an already cached file should still open. For a web document that needs login, use **Open in Browser** when offered.

- [ ] **Start Pi from another app:** Follow the [external link examples](EXTERNAL_PI_LINKS.md). Confirm the prompt, Slack context, and source link reach a new Pi chat. Repeat the same request ID: it should reopen that chat without sending twice. Try with Herdr closed and with an explicit workspace target.

- [ ] **Session bubbles:** Start a Pi chat. Check three lines inside one bubble: the chat name in bold, an emoji beside italic activity, then a separate status icon and **Running**, **Finished**, or **Needs your attention**. The activity updates as Pi works, with an AI topic summary as fallback. Rename the chat and confirm the bold name follows it. Expand a long session list and scroll to the bottom. Try 160% text size, hover attachments, and use the audio controls to check they remain readable beside the taller bubbles.

- [ ] **HUD attachments:** Drop an image and a small text file from Finder into the open HUD. Check the attachment chips, remove one, and send the other. Repeat with a file and no message. Sent files appear in chat; Herdr keeps a copy so attachments survive moving the original and restarting.

- [ ] **Screenshot thumbnail drop:** Take a screenshot with ⇧⌘5 (or ⇧⌘4) and drag the preview thumbnail straight into the open HUD chat or onto the collapsed orb without saving it first. The HUD should highlight while you drag and stage the PNG beside your draft. Drop it on the Desktop first and repeat from there: both routes should end in the same staged attachment.

- [ ] **App Shots is never silent:** Open **Settings → HUD → App Shots** and watch the Command keys readout while you hold the left, then the right Command key. Press both together: the HUD notice should show **Capturing frontmost window…** and then **Screenshot added to New chat**. Repeat with the HUD hidden (turn the HUD off first) and confirm the macOS notification appears, the HUD turns itself back on, and the image is staged. Repeat with Screen Recording denied to confirm the failure is shown and recorded under **Last** in the same section.

- [ ] **Every capture route:** From a frontmost app that is not Herdr, press ⌃⌥C, then use **File → Capture Frontmost Window**, then **Capture frontmost window** in the orb's context menu, then **Test capture now** in Settings. All four should stage the same kind of PNG in a new HUD chat, and **Last** should name the route that fired.

- [ ] **App Shots target:** With Herdr's HUD open and focused, press both Command keys. The capture should be of the app you were using before Herdr, not of the HUD.

- [ ] **Update indicator:** In a signed release build with an update available, the window's top bar shows a version badge. Choose **Later** on the banner: the banner disappears and the badge stays. Click the badge to reopen the update, and confirm **Settings → Updates** reports the channel, the ten-minute cadence, and the last check.

- [ ] **Favorite models and short names:** In a model picker, choose **Favorite [current model]** or **Manage Favorites**. Favorites should appear first in HUD and chat-pane pickers, using consistent short names. Unfavorite one and restart to check persistence. Matching names from different providers remain distinguishable.

- [ ] **Code-block paste:** Copy code and click **Paste Code Block** in each composer. The draft should contain opening triple backticks, your text on the next lines, and closing triple backticks. It waits for you to send. Existing backticks get a longer outer fence so the pasted block stays intact.

- [ ] **No false overflow notification:** With four or more Pi sessions and all alerts read, collapse the HUD. **+1** or **+N** should count extra sessions without creating a red notification border or badge. Actual unread results still trigger attention.

- [ ] **Session links and files:** Have two agents produce different links or result files. Each should attach to its own session bubble and appear inside that chat. Read one session: only its unread indicators should clear. Its result cards should remain in chat history.

- [ ] **Prompt history:** Submit several prompts, then click **Prompt history** in the pane header. Search, expand, copy, and **Reuse** an older prompt. Reuse replaces the draft without sending. Switch panes and restart: history should stay separate and persist. This saves new submissions and imports available earlier prompts; it cannot recover already-lost history.

- [ ] **Compact notes:** Hover over several notes. They should stay as compact title strips until clicked. Close an opened note to return to the compact stack; scroll to reach older notes.

- [ ] **Smaller hover area:** Move the pointer near, then onto, the HUD and notes. Nearby empty space should trigger fewer accidental hover effects; visible controls should remain easy to use.

- [ ] **Recording permissions:** In **Settings > Privacy & Access > Screen & System Audio Recording**, use **Identify this copy of Herdr** and **Test Access**. If access fails, quit Herdr, remove the stale macOS permission entry, add `/Applications/Herdr.app`, enable it, and reopen. The test lists displays, without recording. This adds diagnosis and recovery; macOS still needs your grant, and replacing this build can change its signing identity. [Recovery instructions](RECORDING_PERMISSIONS.md).

## PR Review

Use `-HerdrDemoMode` for the synthetic review, or a disposable pull request on a companion advertising `pr-review-v1`.

These scenarios are pending until the final gate runs them. A reviewed source tree and generated
screenshots are layout evidence, not installed-app verification. The comment scenarios below
include a read-only browser check and remain pending until an operator performs them and records
the actual UI/browser result.

- [ ] **Entry point:** Click **PR Review** under First Mate in the left navigator (or ⌘8). The left column becomes the review rail with an **All sessions** back link; the toolbar shows a PR Review label instead of the segment picker. Back and Forward return to the previous pane.
- [ ] **Paste a PR link:** Paste `https://github.com/example-owner/example-repo/pull/42` into the rail field and press Return. The start sheet lists skills grouped Review / Explainer videos / Utilities / Custom; **Start review** creates the review and it appears selected with a Preparing pill, then Ready.
- [ ] **Files, filters, order:** Impact dots and reasons are visible; choosing High shows only high-impact files; **Hide viewed** removes viewed rows; **Guided** reorders files and shows the reason note above the diff; ⌥↑/⌥↓ move between files; ⌥V toggles viewed.
- [ ] **Diff and Ask AI:** Added, removed and hunk lines are tinted full width with old | new numbers. Select a few lines: the floating **Ask AI** button and the right-click item open the question popover; Send opens the Ask window with the file, side, lines and findings listed in its context.
- [ ] **Deleted files:** Select a deleted text file. Its rail row and selected-file header show a readable **Deleted** label, the header shows a compact removal summary (`Deleted · N lines removed`), and no removed lines are rendered until you choose **Show deleted content**. The full path stays available on hover and to accessibility, and a modified file that contains removal lines is never labeled deleted.
- [ ] **Expand and collapse deleted content:** Choose **Show deleted content** on a deleted source file and on a deleted prose file. The removed hunks render with original-side line numbers, syntax treatment, both scroll axes and working text selection; **Hide deleted content** removes the code again. The choice survives ordinary file navigation, a viewed toggle and an unchanged refresh in the same window, but a newly opened window, another host, review or base/head revision starts collapsed.
- [ ] **Ask AI on deleted content:** Expand a deleted file, select removed code and open **Ask AI**. Type a nonempty draft and confirm the Hide control is unavailable (a draft is never discarded), then Cancel and confirm Hide works again. Sending a question does not change the disclosure or viewed state.
- [ ] **Keyboard and VoiceOver:** With a deleted file selected, tab to **Show deleted content** (Full Keyboard Access on) and press Space; VoiceOver should announce the **Deleted file** label with an **Expanded**/**Collapsed** value and operate the control. ⌥↑/⌥↓ still move between files, and an expanded or collapsed choice survives that navigation.
- [ ] **Navigation and partial diffs:** With a deleted file collapsed, run `herdr-control … ui invoke pr-review.scroll-to-line` (or `highlight-lines`) for one of its removed lines: the content reveals itself and scrolls. Hide it again and let a stale request arrive: it must stay hidden. A truncated deleted patch keeps the partial-diff warning and full-diff link while collapsed; binary, empty, missing and failed diffs keep their existing messages.
- [ ] **Independent windows and long paths:** Pop out the same review and compare disclosure choices: each window keeps its own per-file state, and the main window is never retargeted. In the minimum-size pop-out and at enlarged text, the Deleted label, filename and summary stay readable, the complete path remains available on hover and to accessibility, the disclosure and navigation actions stay inside the diff pane (stacking onto another row when the header is narrow), and expanding still scrolls on both axes.
- [ ] **Deleted-file compatibility:** Confirm the deleted-file presentation works against a companion that advertises only `pr-review-v1`; no server update is required, and disclosure state is neither stored nor synchronized.
- [ ] **Local comment selection and save:** Select added, removed and context lines, including one selection that crosses sides. The floating controls show **Ask AI** and **Add comment**; right-click still opens the Ask AI field. Choose **Add comment**: the editor names the file, the before/after lines, the saved revision and the exact selected code. Save a multiline Markdown comment with an internal blank line, trailing spaces, and a non-ASCII character, then confirm the list shows the same text and the compact code preview. Cancel a dirty editor and confirm the discard confirmation; no record is created. Confirm the review header's **Comments** count/button is available on Files, Context, Agents and Skills while filters are applied and after clearing them, and from a popped-out window.
- [ ] **Preview, edit and local location:** In the list, each comment shows its file, side and line ranges, a compact saved excerpt, and **Show full selection** when the excerpt exceeds three lines. **Edit** updates the text in place. **Show in diff** reaches the exact saved file and span even when a text or impact filter previously hid every file and another tab was active; confirm the filter is cleared and the correct side/line is highlighted.
- [ ] **Copy and read-only GitHub link check:** With a saved comment, use **Copy comment** and paste elsewhere: only the exact Markdown body is copied, with no status or added text. On an already available disposable PR only, activate **Open file in GitHub** and confirm the browser opens the PR's **Files changed** view at the exact file named in the comment (repeat for a renamed, deleted or non-ASCII path if the disposable PR provides one). This is read-only: never submit a comment or review, and confirm Herdr reports no publication state. Confirm the opened URL contains no comment text, token, credential or query payload, and that neither **Copy comment** nor **Open file in GitHub** transmits the comment. Record the observed browser target as the manual file-anchoring evidence.
- [ ] **Failure scenarios:** Point the demo or a test launch at a preserved corrupt or unknown-version comment file (or otherwise make the store unwritable). Confirm the storage-error banner appears, Save keeps the exact draft text on screen, no success is reported, and the original file bytes are unchanged; blank text cannot be saved. Restore valid storage and confirm a retry saves normally.
- [ ] **Refresh and earlier revision:** With a comment saved, let the PR receive a new revision (a disposable PR push) and Refresh. The comment remains readable with an **Earlier revision** badge and its saved excerpt; **Show in diff** does not highlight unrelated current lines and explains why. If the saved commit still exists, **Open original revision** opens the recorded file at that revision; a file removed by the new revision shows **Not in current revision** and is never silently remapped or deleted. No comment is lost or rewritten by the refresh.
- [ ] **Shared windows, isolation and relaunch:** Save a comment in the main window, pop the review out, and confirm the pop-out list shows the same record; edit it there and confirm the main list updates. Open two reviews (or the same review id on two hosts) and confirm each list contains only its own records. Archive a review with saved comments: it leaves Active, its comments remain readable under Archived with the same text and anchors, and Unarchive changes nothing. Quit and relaunch the app: the comment count, exact multiline text, code excerpt, side/line metadata and revision state all return from the same store.
- [ ] **Review window styling parity:** open the same synthetic patch in the production Git segment (open a workspace pane, choose **Git** mode, then **View diff** for the file) and in PR Review, and compare them side by side. Added rows carry the same full-width green tint, removed rows the same red tint, the line-number gutter is visibly darker than the row, and changed words inside a replaced line are stronger still; unchanged context and hunk headers stay distinguishable. Repeat at the largest text size, then scroll vertically and horizontally and confirm no background is dropped. Compare against the live Git segment, not the simplified demo Git view.
- [ ] **Pop out an active review:** Right-click an active row — including one that is not currently selected — and the header of the open review. **Pop Out into Window** appears on both, opens that exact review in its own resizable window, and leaves the main window's selection unchanged. The window keeps Files, Context, Agents, Skills, Ask AI, selection, and both scroll axes usable.
- [ ] **One window per review:** Open two active reviews at once. Switch tabs and select a different file in one window; the other keeps its own review, tab, and file. Reopen one review: its existing window comes forward without a duplicate. Close one window: the other window and the main window stay usable, and the review is still listed under Active (closing is not archiving). Reopen it and confirm it returns to its own review.
- [ ] **Review windows beside chat work:** With two review windows open, return with **All sessions** to the chat navigator, open two chats, and type an unsent draft in the first. Switch to the second chat and back: the draft is exactly as typed, both review windows still show their own reviews, and the main window keeps normal navigation, including Back/Forward and ⌘8.
- [ ] **Pinned host and unavailable state:** With a review window open, switch the main window's PR review host and select another review. The popped-out window keeps its original review and host for Ask AI, documents, agents, and refresh, and the main window's host selector cannot retarget it. Remove that host from Settings → Machines: the window shows an unavailable message instead of falling back to another machine. Settings → Add Machine assigns a new machine id, so adding the same URL again does not restore this window; close the unavailable window and open the review from the newly added machine, or keep the original machine entry configured. The window never guesses an identity from the URL.
- [ ] **Duplicate display labels and ids:** Open two reviews on the same host that share a title or a pull request number and confirm each gets its own window. If two configured hosts expose the same server-local review id, each still gets a separate window. Nothing here changes the review's repository number, list order, or labels.
- [ ] **Context:** Drop a markdown file and a folder onto the Context tab; allowed files appear with "Added by you"; a markdown document opens in-app; an HTML report opens in the in-app viewer; audio/video open in QuickTime Player. With a Markdown or HTML document window open, its Context row reports Ready and Reveal in Finder selects the cached file. Rotate that machine's token in Settings → Machines: the retained document window keeps working against the same host, and removing the host turns it into an unavailable window rather than falling back to another machine.
- [ ] **Agents and Skills:** A running skill shows a pane and latest output; **Finish** moves it to Finished and its outputs appear under Context; Skills shows ✓ Ran with the run count; **Mark as not run** flips the state; **Add custom skill…** adds a row that can be run.
- [ ] **Archive, never delete:** Archive a review; it leaves Active, appears under Archived with all documents and runs, and Unarchive restores it.
- [ ] **Agent control:** `herdr-control --control-machine <id> ui segment pr-review --wait 30` opens the section; `ui invoke pr-review.scroll-to-line` with a path and line scrolls and flashes that line; `pr-review.state` returns the selected file and visible range.

## Response briefs

Enable briefs on a disposable synthetic Pi chat with a connected companion and use fictional answers only. The app-wide length preset is one setting for this Mac; model and thinking stay separate.

- [ ] **Live-to-snapshot refresh:** Complete a short synthetic answer, let it persist, then refresh the conversation or relaunch the app and reopen the chat. The answer should get one brief without a duplicate paid request, and the rail must not show **Some completed responses could not be matched to the saved brief baseline.**
- [ ] **Tiny answers:** Confirm a valid brief generates for a one-character answer, an emoji-only answer, and synthetic answers at 159, 160, and 161 readable letter/number characters. Each generated summary must be valid and may be very short; it must not contain filler, placeholders, or ellipses. An empty or whitespace-only answer, a streaming or failed/aborted conclusion, and a tool-only conclusion must make no request. One newly eligible latest answer generates once and does not backfill older skipped history.
- [ ] **Each preset:** Generate the same synthetic source with Length set to Minimal, Medium, and Long. Minimal keeps visible content at or below 40 words and 240 non-whitespace scalars; Medium at 80/480; Long at 120/720. Confirm the allowance is an upper bound—a tiny answer stays a tiny summary—and that the `Length · …` menu is separate from Thinking and exposes the accessible label **Brief length**.
- [ ] **Selected prior-source regeneration:** Select a prior brief in **Generated source**, change Length, and confirm a fresh brief appears for that exact source rather than the latest answer. Switch back to a previously used preset and confirm another fresh generation. Re-selecting the current value does nothing, and other chats and saved records are unchanged. With **Select prior brief** active, changing Length targets the latest completed answer.
- [ ] **Relaunch and in-flight change:** Start a generation, change Length while it runs, and relaunch before a replacement is submitted. Accepted work must reconcile under its captured preset, and the latest selection must resume exactly once and appear afterwards; a superseded preflight selection must never reach the paid endpoint. Repeated changes while the intent save is pending must leave only the newest selection durable even if the app exits immediately after, and the preset must survive relaunch; an invalid or absent stored value falls back to Minimal.
- [ ] **Transport-uncertain receipt:** Interrupt a submission before its run ID returns, then relaunch and reopen the chat. The rail must show an actionable retry message for that exact source rather than an empty idle state, and **Retry brief** must replay the same saved request once before any replacement runs.
- [ ] **Older-server messaging:** Against a companion that advertises `response-brief-v1` but not `responseBriefs.lengthPolicyVersion` 2, complete a new synthetic answer or change Length. The rail should say **Update the companion for configurable brief length (minimal, medium, long). This request was not sent and no fallback was used.** with **Retry after updating**; no generic-agent run should start. Previously accepted legacy runs must still reconcile, and **Retry after updating** must work after the companion is upgraded and support is reloaded. When a length change is already queued, that retry (or **Reload brief support and models**) must submit the queued replacement exactly once: no second request may appear on the next poll or after a relaunch, and turning the chat off while the queued change is still saving must leave nothing to resume when it is turned back on.
- [ ] **Settled failure retry:** Force a completed run with no usable brief (a terminal provider failure or invalid output). **Retry brief** must keep the explicit **Regenerate this brief** / **Regenerate latest response** control available instead of leaving an empty idle rail, and regenerating must create exactly one fresh request that stores a valid brief.
- [ ] **Baseline recovery:** Using the deterministic legacy cursor-only cache scenario or a session whose saved baseline is absent from the current snapshot, confirm the warning appears and that Retry alone does not clear it. When a later persisted projection proves continuity, the warning must disappear on its own without another paid request. The reconciled card must stay labeled **Latest** in **Generated source**, with no **Pinned to a prior response** note and no separate **Full selected prior original** action. Choose **Restart briefs from latest response**, confirm **Restart from latest**, and verify only the latest answer generates once with no historical backfill, including when an earlier accepted receipt is still settling or the app exits before the replacement starts. Repeated identical answers must remain distinct responses.
- [ ] **Wide and narrow large-text presentation:** At a wide window the rail shows the Length control and complete card beside the bounded reading column. At a narrow window or large text size, **Open brief** presents the sheet fallback without clipping, and the delivery validator compares the result with the synthetic wide, narrow, and large-text render artifacts.

## Tab colors and sidebar filtering

These preferences are local to this Mac. Smart Rename inside this section
requires the execution companion to advertise the tool-free naming profile; the
color assignments and labels themselves need no server update.
The optional companion sharing and CLI discovery checks at the end require a
companion advertising `chat-tab-colors-v1` and the matching installed CLIs; the
Mac updater installs neither.

- [ ] Right-click a tab or a chat in Recents → **Tab color**. Try all six colors. Check the menu swatches, selected checkmark, and sidebar row fills. Pi chat, header, composer, and workspace card backgrounds must remain unchanged. Sibling chats and new panes in the same tab inherit the color; an identically numbered tab on another machine does not.
- [ ] Confirm the color key appears below **Filter chats** and above **New session**. Click a label: only matching chats remain, including in Unread, Starred, and workspace groups. Combine with text search, machine scope, and recency. Click again or **Show all colors** to clear. Remove the last matching tab's color while filtered: a clearable empty state remains. **Reveal in Sidebar** clears the color filter.
- [ ] Check the 56-point color-key rows and larger titles. Click the pencil beside a color label while Filter chats has focus, then type immediately without clicking the editor: the selected label should be replaced and the filter should remain untouched. Enter and clicking away save; Escape cancels. Empty, multiline, or over-80-character labels preserve the previous value with feedback. Right-click → **Smart Rename** with readable Pi chats containing a synthetic Jira key/title. Edit the label or reassign a tab, or submit a newer prompt on a sampled pane, while AI is running: the late result must not replace your change. Failure must retain the old label and clear the spinner, and invalid output must name the model, effort, and companion without echoing the model text. Save a model the naming machine does not offer: the label must stay unchanged with an actionable error that names the selection and companion, never a substituted default. Then retry with shell-only panes in the same color: the label must still be nameable from bounded terminal output or pane metadata, using the naming machine of the first successfully sampled pane.
- [ ] Relaunch: assignments and custom labels persist. Remove a tab's color: every sibling returns to its normal background, without changing its title, status, or unread state. Check large text, keyboard navigation, VoiceOver color-group labels, and **Differentiate without color** (numbered sidebar symbols).

### Tab color discovery with a synthetic companion

Use a test companion, synthetic labels, and synthetic tab names. Never publish
captured chats, private machine names, or personal labels.

- [ ] **Sharing is separate from agent control:** Leave **Allow agent control** off. In Settings → Privacy → Tab colors, turn on **Share tab colors with companions** and note this Mac's **Installation** ID. Assign a synthetic label (for example "Synthetic Release Group") to two tabs, then read `GET /api/v1/snapshot` or run `herdr-control --machine <id> find chats --color <palette>`: each affected tab should report this installation's `clientId`, the color, and the effective label; a tab with no color should appear as `unassigned`, and a tab this Mac does not know should appear as `unavailable`, never `unassigned`. With sharing off, nothing is published.
- [ ] **Both CLIs agree:** With the synthetic label, run `herdr-control --machine <id> find chats --color <palette>` or `--color-label "Synthetic Release Group"`, then add `--group-by color|label`. Also run `herdr-hud-chats list --scope terminal --color <palette>`. Both CLIs should list the same chats, groups should stay separated by publisher installation, and an ordinary saved `herdr-hud-chats list` should be unchanged.
- [ ] **Rename, reset, and remove:** Rename the color. After the next publication the new text should match and the old text should not. Reset the label to the palette default (for example "Sage"), then remove a tab's color: that tab should become explicitly unassigned and `--color none` should match it. A tab omitted from a synthetic publication should report `unavailable` and must never match `--color none`.
- [ ] **Disconnect, stale, and disable:** Stop or disconnect the companion and wait past 60 seconds: reads should still return the last-known values marked `stale`. Reconnect and verify they refresh. Turn sharing off: exported values should be withdrawn, color filters should return no false matches, and the local assignments should remain on this Mac.
- [ ] **Read-only control:** `herdr-control --control-machine <id> ui actions` should list `chat.tab-color` disabled with a read-only reason, and `ui invoke chat.tab-color` should fail without changing any color. Manual editing must continue to work.

## iPhone notification checks

The backend waits until an agent has been **finished or needs attention for 60 seconds unread**, then sends an iPhone notification. Reading, closing, or resuming the session cancels pending delivery. Failed deliveries retry without repeating successful ones.

Once Apple push is configured and the updated iOS app is installed with notifications enabled:

- [ ] Let an agent finish while the iPhone app is in the background. Leave the session unread for more than a minute. Expect one notification; tap it and confirm it opens the correct machine and chat.
- [ ] Repeat, but read the session within the first minute. Expect no delayed push for that result.
- [ ] With the iOS app connected, verify its local fallback also waits a minute and that reading the session clears matching notifications when read state syncs.


## Pi compaction completion

Use a disposable synthetic Pi chat served by a companion that provides Pi snapshots. These checks cover the cue beside the prompt, not the transcript's summary entry. A reviewed source tree and generated render artifacts are layout evidence, not installed-app verification.

- [ ] **Manual success:** Ask Pi to compact (the More → Compact chat action). While it runs, the composer keeps its compacting spinner and Send stays unavailable. When Pi confirms success, a checkmark and **Context compacted** replace the spinner beside the prompt, even when no assistant reply follows. Type a draft and confirm the cue and its readiness line stay; send the draft and confirm only the cue disappears while the transcript's **Context compacted** entry remains.
- [ ] **Automatic and overflow:** Let a long synthetic session cross the automatic threshold, and separately force an overflow compaction. Both end in the same completed cue. Its readiness line must say **Ready for your next message.** only when the session is connected and idle; while Pi is still working it must describe the available steer/follow-up modes instead of claiming idle.
- [ ] **Failure, cancellation, and ambiguous endings:** Cancel a manual compaction and force a compaction failure. The spinner clears and no completed cue appears. If a cue existed before the new attempt, it must not come back after the failed or ambiguous attempt.
- [ ] **Reconnect and session scoping:** With a completed cue, disconnect the companion or refresh the chat. The cue may remain, but the readiness line must read **Pi is offline. Reconnect before sending a message.** After reconnecting to the same session it returns to **Ready for your next message.** Switch to another chat or session and back, and navigate to another branch: no unrelated cue may appear.
- [ ] **Draft preservation and explicit send:** With a completed cue and a staged attachment, confirm Send is enabled only for a valid non-empty draft, the draft and attachment survive compaction, and nothing is sent until you explicitly press Send or Return. A failed send must leave the cue and the draft in place.

## Chat activity, HUD controls, and navigation

Use synthetic demo data or a disposable test conversation for these checks.

- Turn on Settings > General > Chat > Group all Clanking activity. Send a prompt that produces
  interim text, several tool calls, and a final answer. Confirm one collapsed
  Clanking row stays between the prompt and final answer. Expand it during work,
  confirm activity updates without changing the expansion choice, then collapse it.
- Confirm the final answer stays hidden until the turn finishes. Check an answer
  with multiple text blocks, a stopped turn, a tool failure, and an input request.
  Failures and requests must remain discoverable and usable. Turn grouping off and
  verify the original transcript order returns without losing any text.
- In a HUD chat, verify Clanking never expands automatically on a tool failure.
  Run a request and confirm the collapsed bubble and open chat have yellow borders;
  completion should return to the appropriate completed/idle appearance.
- Right-click a HUD chat and choose Smart Rename. Verify loading, a short title,
  persistence after restart and after remove/reopen from history, and an error
  when naming cannot finish. Switch to another chat while naming and verify the
  original chat is renamed. Removing/ending a chat must not let a stale result
  affect a replacement chat. Save a model the chat's execution companion does not
  offer in Settings → Agents → Smart Rename: the rename must stop, keep the
  current title, leave the saved selection in place, and name the selection and
  companion in the error. Repeat with an Agent model inherited by an empty Smart
  Rename model, and with a non-reasoning model paired with an effort above Off.
  Confirm that Off is accepted and an offered selection is sent unchanged.
- On a companion whose server predates the tool-free `smart-rename-v1` naming
  profile, run Smart Rename: no request should reach the companion, the current
  title must stay, and the error must name the companion and ask for its server
  update. Confirm the tool-free path on an updated companion by checking the
  dispatched run profile, and confirm the model output rules still apply: a
  non-JSON, over-80-character, or control-character title names the model,
  effort, and companion without echoing the raw output, and never changes the
  title or saved selection.
- Smart Rename immediately after submitting a HUD prompt, before any reply or
  tool activity appears. It must succeed from the submitted prompt alone. Let a
  reply and completion arrive while the naming spinner is still visible: the
  title must still be applied. Repeat with a running chat that has no assistant
  text yet. Rename one pending chat and then accept a second chat with the same
  prompt prefix first: the title must remain owned by its own chat, and each
  chat must keep the right title after relaunch and reopen from history.
- Run the synthetic matrix in [docs/smart-rename.md](../docs/smart-rename.md)
  with disposable machines whose companions advertise different model catalogs.
  Confirm each rename runs on the target pane's or HUD chat's machine: an offered
  selection is sent unchanged, while a missing explicit or inherited model, an
  unreadable or empty catalog, or a non-reasoning model above Off keeps the
  original title, leaves Settings unchanged, and shows an actionable error that
  names the companion and selection — never a fallback. Verify a catalog-listed
  model whose provider fails also preserves the title with one attempt. Edit a
  title while naming is in flight; the manual edit must win. Never use production
  machines, credentials, or real conversations for this check; the required
  per-companion smoke checks are recorded privately by the single validation
  owner, inaccessible machines remain unverified, and unperformed checks stay
  unperformed rather than passing.
- Open Git in a new window, resize it, switch the main chat to another repository,
  and verify the detached view remains on its original pane and machine. Reopen
  the same target and verify its existing window is used. Test disconnect/reconnect
  and a removed pane, and check existing read-only restrictions.
- Verify All, Today, and Recents range segments. With 0 machines verify the machine
  selector is hidden. With 1, 2, and 3 machines verify machine segments; with 4
  verify the menu. All must remain available, and Manage Machines must remain in
  the sidebar footer. Check long names, a narrow sidebar, VoiceOver labels, and
  increased app text size. Confirm archived Previous chat sections retain their
  existing excerpt presentation.

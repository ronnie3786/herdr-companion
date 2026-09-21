# Herdr Mac manual test checklist

Use your configured Herdr Mac build with sample sessions. Check off each item after trying it.

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

- [ ] **Entry point:** Click **PR Review** under First Mate in the left navigator (or ⌘8). The left column becomes the review rail with an **All sessions** back link; the toolbar shows a PR Review label instead of the segment picker. Back and Forward return to the previous pane.
- [ ] **Paste a PR link:** Paste `https://github.com/example-owner/example-repo/pull/42` into the rail field and press Return. The start sheet lists skills grouped Review / Explainer videos / Utilities / Custom; **Start review** creates the review and it appears selected with a Preparing pill, then Ready.
- [ ] **Files, filters, order:** Impact dots and reasons are visible; choosing High shows only high-impact files; **Hide viewed** removes viewed rows; **Guided** reorders files and shows the reason note above the diff; ⌥↑/⌥↓ move between files; ⌥V toggles viewed.
- [ ] **Diff and Ask AI:** Added, removed and hunk lines are tinted full width with old | new numbers. Select a few lines: the floating **Ask AI** button and the right-click item open the question popover; Send opens the Ask window with the file, side, lines and findings listed in its context.
- [ ] **Context:** Drop a markdown file and a folder onto the Context tab; allowed files appear with "Added by you"; a markdown document opens in-app; an HTML report opens in the in-app viewer; audio/video open in QuickTime Player.
- [ ] **Agents and Skills:** A running skill shows a pane and latest output; **Finish** moves it to Finished and its outputs appear under Context; Skills shows ✓ Ran with the run count; **Mark as not run** flips the state; **Add custom skill…** adds a row that can be run.
- [ ] **Archive, never delete:** Archive a review; it leaves Active, appears under Archived with all documents and runs, and Unarchive restores it.
- [ ] **Agent control:** `herdr-control --control-machine <id> ui segment pr-review --wait 30` opens the section; `ui invoke pr-review.scroll-to-line` with a path and line scrolls and flashes that line; `pr-review.state` returns the selected file and visible range.

## Tab colors and sidebar filtering

These preferences are local to this Mac. Smart Rename inside this section
requires the execution companion to advertise the tool-free naming profile; the
color assignments and labels themselves need no server update.

- [ ] Right-click a tab or a chat in Recents → **Tab color**. Try all six colors. Check the menu swatches, selected checkmark, and sidebar row fills. Pi chat, header, composer, and workspace card backgrounds must remain unchanged. Sibling chats and new panes in the same tab inherit the color; an identically numbered tab on another machine does not.
- [ ] Confirm the color key appears below **Filter chats** and above **New session**. Click a label: only matching chats remain, including in Unread, Starred, and workspace groups. Combine with text search, machine scope, and recency. Click again or **Show all colors** to clear. Remove the last matching tab's color while filtered: a clearable empty state remains. **Reveal in Sidebar** clears the color filter.
- [ ] Check the 56-point color-key rows and larger titles. Click the pencil beside a color label while Filter chats has focus, then type immediately without clicking the editor: the selected label should be replaced and the filter should remain untouched. Enter and clicking away save; Escape cancels. Empty, multiline, or over-80-character labels preserve the previous value with feedback. Right-click → **Smart Rename** with readable Pi chats containing a synthetic Jira key/title. Edit the label or reassign a tab, or submit a newer prompt on a sampled pane, while AI is running: the late result must not replace your change. Failure must retain the old label and clear the spinner, and invalid output must name the model, effort, and companion without echoing the model text. Save a model the naming machine does not offer: the label must stay unchanged with an actionable error that names the selection and companion, never a substituted default. Then retry with shell-only panes in the same color: the label must still be nameable from bounded terminal output or pane metadata, using the naming machine of the first successfully sampled pane.
- [ ] Relaunch: assignments and custom labels persist. Remove a tab's color: every sibling returns to its normal background, without changing its title, status, or unread state. Check large text, keyboard navigation, VoiceOver color-group labels, and **Differentiate without color** (numbered sidebar symbols).

## iPhone notification checks

The backend waits until an agent has been **finished or needs attention for 60 seconds unread**, then sends an iPhone notification. Reading, closing, or resuming the session cancels pending delivery. Failed deliveries retry without repeating successful ones.

Once Apple push is configured and the updated iOS app is installed with notifications enabled:

- [ ] Let an agent finish while the iPhone app is in the background. Leave the session unread for more than a minute. Expect one notification; tap it and confirm it opens the correct machine and chat.
- [ ] Repeat, but read the session within the first minute. Expect no delayed push for that result.
- [ ] With the iOS app connected, verify its local fallback also waits a minute and that reading the session clears matching notifications when read state syncs.


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

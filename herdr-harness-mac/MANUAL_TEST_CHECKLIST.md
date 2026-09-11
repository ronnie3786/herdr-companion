# Herdr Mac manual test checklist

Use your configured Herdr Mac build with sample sessions. Check off each item after trying it.

- [ ] **Attachment titles on hover:** Have a session return several documents. At rest they should be icons. Hover the orb or any visible HUD control: all visible document titles should expand beside that session. Move between titles and click one, then move away to restore icons.

- [ ] **Documents belong to responses:** Have the same agent return different documents in two replies. Open Chat: each card should sit beneath the reply that produced it. Switch sessions and reopen an older chat to check that cards stay with the correct response.

- [ ] **Unavailable documents:** Try an expired result file or a known deleted document link. Expect a clear alert. An offline source Mac should show a connection message; an already cached file should still open. For a web document that needs login, use **Open in Browser** when offered.

- [ ] **Start Pi from another app:** Follow the [external link examples](EXTERNAL_PI_LINKS.md). Confirm the prompt, Slack context, and source link reach a new Pi chat. Repeat the same request ID: it should reopen that chat without sending twice. Try with Herdr closed and with an explicit workspace target.

- [ ] **Session bubbles:** Start a Pi chat. Check three lines inside one bubble: the chat name in bold, an emoji beside italic activity, then a separate status icon and **Running**, **Finished**, or **Needs your attention**. The activity updates as Pi works, with an AI topic summary as fallback. Rename the chat and confirm the bold name follows it. Expand a long session list and scroll to the bottom. Try 160% text size, hover attachments, and use the audio controls to check they remain readable beside the taller bubbles.

- [ ] **HUD attachments:** Drop an image and a small text file from Finder into the open HUD. Check the attachment chips, remove one, and send the other. Repeat with a file and no message. Sent files appear in chat; Herdr keeps a copy so attachments survive moving the original and restarting.

- [ ] **Favorite models and short names:** In a model picker, choose **Favorite [current model]** or **Manage Favorites**. Favorites should appear first in HUD and chat-pane pickers, using consistent short names. Unfavorite one and restart to check persistence. Matching names from different providers remain distinguishable.

- [ ] **Code-block paste:** Copy code and click **Paste Code Block** in each composer. The draft should contain opening triple backticks, your text on the next lines, and closing triple backticks. It waits for you to send. Existing backticks get a longer outer fence so the pasted block stays intact.

- [ ] **No false overflow notification:** With four or more Pi sessions and all alerts read, collapse the HUD. **+1** or **+N** should count extra sessions without creating a red notification border or badge. Actual unread results still trigger attention.

- [ ] **Session links and files:** Have two agents produce different links or result files. Each should attach to its own session bubble and appear inside that chat. Read one session: only its unread indicators should clear. Its result cards should remain in chat history.

- [ ] **Prompt history:** Submit several prompts, then click **Prompt history** in the pane header. Search, expand, copy, and **Reuse** an older prompt. Reuse replaces the draft without sending. Switch panes and restart: history should stay separate and persist. This saves new submissions and imports available earlier prompts; it cannot recover already-lost history.

- [ ] **Compact notes:** Hover over several notes. They should stay as compact title strips until clicked. Close an opened note to return to the compact stack; scroll to reach older notes.

- [ ] **Smaller hover area:** Move the pointer near, then onto, the HUD and notes. Nearby empty space should trigger fewer accidental hover effects; visible controls should remain easy to use.

- [ ] **Recording permissions:** In **Settings > Screen & System Audio Recording**, use **Identify this copy of Herdr** and **Test Access**. If access fails, quit Herdr, remove the stale macOS permission entry, add `/Applications/Herdr.app`, enable it, and reopen. The test lists displays, without recording. This adds diagnosis and recovery; macOS still needs your grant, and replacing this build can change its signing identity. [Recovery instructions](RECORDING_PERMISSIONS.md).

## Tab colors and sidebar filtering

These preferences are local to this Mac; no server update is needed.

- [ ] Right-click a tab or a chat in Recents → **Tab color**. Try all six colors. Check the menu swatches, selected checkmark, and sidebar row fills. Pi chat, header, composer, and workspace card backgrounds must remain unchanged. Sibling chats and new panes in the same tab inherit the color; an identically numbered tab on another machine does not.
- [ ] Confirm the color key appears below **Filter chats** and above **New session**. Click a label: only matching chats remain, including in Unread, Starred, and workspace groups. Combine with text search, machine scope, and recency. Click again or **Show all colors** to clear. Remove the last matching tab's color while filtered: a clearable empty state remains. **Reveal in Sidebar** clears the color filter.
- [ ] Check the 56-point color-key rows and larger titles. Click the pencil beside a color label while Filter chats has focus, then type immediately without clicking the editor: the selected label should be replaced and the filter should remain untouched. Enter and clicking away save; Escape cancels. Empty, multiline, or over-80-character labels preserve the previous value with feedback. Right-click → **Smart Rename** with readable Pi chats containing a synthetic Jira key/title. Edit the label or reassign a tab while AI is running: the late result must not replace your change. Failure must retain the old label and clear the spinner.
- [ ] Relaunch: assignments and custom labels persist. Remove a tab's color: every sibling returns to its normal background, without changing its title, status, or unread state. Check large text, keyboard navigation, VoiceOver color-group labels, and **Differentiate without color** (numbered sidebar symbols).

## iPhone notification checks

The backend waits until an agent has been **finished or needs attention for 60 seconds unread**, then sends an iPhone notification. Reading, closing, or resuming the session cancels pending delivery. Failed deliveries retry without repeating successful ones.

Once Apple push is configured and the updated iOS app is installed with notifications enabled:

- [ ] Let an agent finish while the iPhone app is in the background. Leave the session unread for more than a minute. Expect one notification; tap it and confirm it opens the correct machine and chat.
- [ ] Repeat, but read the session within the first minute. Expect no delayed push for that result.
- [ ] With the iOS app connected, verify its local fallback also waits a minute and that reading the session clears matching notifications when read state syncs.

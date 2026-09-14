# Independent HUD chats

Start another one-off task without waiting for the previous reply. Sending from
the HUD now creates a separate **HUD chat** bubble beneath the orb and immediately
frees the fresh composer.

- Each chat has its own transcript, draft, attachments, task title, and run state.
- Unread completed replies glow green and say **Ready**. Replies no longer open
  the HUD or steal focus automatically.
- Click a bubble to expand its chat. Reopen the orb or choose **New chat** to
  start another task; existing chats keep running.
- Search **Chat history** while tasks run. Already-open conversations reuse their
  existing bubble instead of creating a second writer.
- Bubbles and unread state survive relaunch. Saved active runs reconnect without
  resending prompts; offline chats block stale follow-ups until status is checked.
- Right-click a finished bubble and choose **Remove from HUD** to hide it without
  deleting its saved history.

**Continue in agent** remains the explicit way to move a full conversation into
a terminal workspace. Regular workspace-agent bubbles retain their existing flow.
The First Mate dark-mode default from the previous preview is preserved.

## Try it

Send a task, reopen the orb, and send a second task. Both should have their own
bubbles. Let a reply finish while editing another draft: it should turn green
without opening a card. Click the bubble to read or continue that chat.

## Compatibility

Mac-only update. Requires the existing companion `hud-chat-v1` capability for HUD
chats; no additional server or Pi package update is needed. Existing server run
concurrency limits and timeouts remain in effect. Model and thinking controls
retain the shared HUD preferences. Unsent drafts remain in memory per chat, not
synced or restored after quitting.

This is a preview signed with Apple Development credentials, not a notarized
Developer ID release. The signed updater remains enabled. The Mac updater does
not install or restart the companion server, and this release does not update iOS.

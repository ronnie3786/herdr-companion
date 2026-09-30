# macOS 0.73.0-beta.1

First Mate chat opens directly without waiting for the feature list. Quiet polls
no longer redraw unchanged conversations, text and file-card processing runs
outside the interface thread, and the composer and message bubbles avoid repeated
layout work. Inactive chat windows refresh less frequently and refresh immediately
when activated.

Overview loads independently from the conversation. Agents, Documents, and Workflow
load their details when opened. With companion **0.67.0b1**, chats open on their
newest 60 messages, **Load earlier messages** retrieves older history, and unchanged
polls return only a version acknowledgement. Scrolling back keeps the transcript
position when new replies arrive or earlier messages load.

Older companions remain supported through the existing snapshot routes. The
rendering, direct-opening, and independent inspector improvements work with them;
smaller conditional responses and paged history require the separate companion
update. The Mac updater does not install server packages.

With preview updates enabled, use **Settings → Updates → Check for Updates…**.
Try typing in an open First Mate chat, switching conversations, opening Overview,
and scrolling back while a reply arrives. On an updated companion, use **Load
earlier messages** to read older history.

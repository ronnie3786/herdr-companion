# macOS 0.14.1-beta.1

## Reliable remote chat recovery

- Reconnecting a Pi chat resumes after the last applied event instead of replacing the conversation with an older checkpoint. Recent tool calls and costs no longer disappear and replay because of an ordinary connection interruption.
- When a session change, compaction, or replay reset requires a full refresh, the app keeps the last coherent conversation visible while it catches up, then replaces it together. Legitimate changes to session history and cost remain supported. If recovery cannot make progress, the app preserves the conversation and asks you to reopen the chat rather than showing an endless reconnect.
- Long active Pi runs can save intermediate checkpoints with the matching bridge update, reducing the backlog when opening a chat or rebuilding its history.
- Regression coverage exercises reconnects, replay, cancellation, session changes, and checkpoint ordering with synthetic data.

## Compatibility and installation

Install through **Herdr Companion → Check for Updates…** with **Include preview builds** enabled. This preview uses Apple Development signing and is not notarized; signed update verification remains enabled.

The Mac reconnect/recovery improvements use the existing semantic API and work without a companion server update. More frequent active-run checkpoints require the matching companion/Pi package, published separately as **companion-v0.14.1-beta.1**. The Mac updater does not install that package, update Pi extensions on another computer, or restart a server. See [the companion update instructions](https://github.com/ronnie3786/herdr-companion/blob/macos-v0.14.1-beta.1/herdr_harness/README.md#update-the-server).

Matching iOS source is included for the next separately delivered iOS build. This Mac release does not update iPhone or iPad.

## Try it

Open a running remote Pi chat, briefly interrupt and restore its network connection, and watch it reconnect. Already displayed tool calls and cost should remain in place while updates resume. A real new session or compaction may legitimately change the displayed history or context.

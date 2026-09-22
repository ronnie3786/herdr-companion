# First Mate feels like Chat

- First Mate now uses Chat's shared prompt composer: multiline editing, attachments and drag-and-drop, voice notes and dictation, Paste code and its keyboard shortcut, and quote chips beside uploaded files.
- Select text in a recent completed First Mate reply and choose **Quote & comment…**. Save stages the excerpt and your comment without sending. Replies and code blocks use Chat's copy controls.
- Unsent drafts, uploads, and quotes remain scoped to their feature while this Mac app runs. Switching features or machines cannot redirect an in-flight upload or reply.
- Choose models and thinking effort through the same controls as Chat. Existing First Mate sessions require an idle boundary and explicit confirmation: switching may reprocess context, invalidate prompt caches, and incur extra cost. Workers keep their own model settings.
- **Main session context** shows the current coordinator's measured tokens, context window, and automatic handoff threshold, separately from total feature cost. First Mate preserves a checkpoint and continues in a fresh session at a safe boundary; it does not use ordinary Pi compaction.

## Try it

Open **First Mate**, select a feature, and use **Attach**, **Paste code**, or **Voice** below the conversation. Quote a recent response, review its chip, then send. Open the context details for usage and handoff guidance. Model selection never starts a new turn by itself.

## Compatibility and installation

The shared editor, quoting, and copying work with existing First Mate text-chat support. Uploads, measured context, and server-enforced model-switch safety require the matching companion package advertising `first-mate-attachments-v1`, `first-mate-context-v1`, and `first-mate-safe-model-settings-v1`. Older servers show an upgrade explanation instead of guessing context usage or switching an established session unsafely.

Update the Mac app through **Herdr Companion → Check for Updates…** with preview builds enabled for a preview release. The signed app updater does not install or restart companion servers. Update the companion package separately using its documented versioned-runtime procedure. Preserve active work and private configuration; no iOS update is required for these Mac features.

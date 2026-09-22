# First Mate chat parity on Mac

The Mac app uses the same `PromptComposerView` for pane Chat and First Mate. First Mate supplies an explicit feature destination; it never creates a placeholder terminal pane or workspace.

## Behavior

- Return sends. Shift-, Option-, and Command-Return insert a newline while preserving native editing and undo behavior.
- **Attach**, drag and drop, upload status, retry, and remove use the selected feature's authenticated host. A failed or uploading selected file blocks sending until it is retried or removed. Attachment-only messages are valid.
- **Paste code** and Command-Shift-V append a fenced clipboard block.
- **Voice** supports note recording, hold-to-dictate, locked recording, and transcription against the feature's host.
- Quotes use the shared quote editor, preview, chips, and inline `Quoted response segments:` serialization. Only the latest three completed text-bearing First Mate responses can be quoted; every visible human or assistant message remains copyable. Saving a quote only stages it.
- Draft text, uploads, quotes, and the dictation marker remain separate for each exact feature/connection lifecycle. Switching features or hosts cannot retarget an in-flight upload, transcription, send, catalog load, or settings save.
- A failed or uncertain send keeps its exact serialized content and request ID for retry. A successful send removes only the text and staged item identities that were accepted, preserving edits or files added while the request was in flight.
- Pane-only terminal keys, Pi maintenance, workspace file search, Jira insertion, skills, and conversation references are not offered for First Mate.

## Context and managed handoff

When the companion advertises `first-mate-context-v1`, the composer reports only the current native coordinator session's measured context tokens, window, percentage, handoff target, and observation time. Zero is a real measurement; missing, malformed, stale-session, or unavailable data is shown as unknown rather than zero.

At 90% of the configured target, the app distinguishes an approaching handoff from a reached threshold. Context details name the actual measurement time and explain the managed behavior: First Mate checkpoints at a safe turn boundary and starts a fresh coordinator while retaining full history. Ordinary compaction is disabled. There is no manual compact or handoff action in this interface.

## Safe model settings

Existing coordinator sessions require `first-mate-safe-model-settings-v1`. Selecting a genuine model or thinking change stages it and asks for explicit confirmation that context may be reprocessed, prompt caches may be invalidated, and additional cost may result. Workers are unaffected. The server applies the choice to the next coordinator turn without resetting the session.

Controls are unavailable while the coordinator owns a turn, a settings/send request is in flight, the feature is closed or offline, or the server cannot safely change an established session. The app submits the current settings revision and exact native session identity; stale or busy responses remain visible. Older servers remain usable for conversation and show an update affordance instead of attempting an unsafe mid-session fallback.

## Compatibility and setup

Attachments require `first-mate-attachments-v1`; context telemetry requires `first-mate-context-v1`; safe established-session settings require `first-mate-safe-model-settings-v1`. These are companion-server capabilities. Updating the Mac app does not update or restart the server.

The upload request contains only `filename`, `content_type`, and `data_base64` and follows the shared 20 MiB attachment limit. The server owns storage under the feature's opaque namespace. Sent prompts reference returned attachment paths with the same ``Attachment: `path` `` convention as pane Chat.

## Manual verification checklist

Use synthetic features, files, messages, clocks, and model names. Do not capture operator configuration or real sessions.

- [ ] In light and dark appearance at every app text-size setting, long Markdown, code, quote chips, attachment errors, context status, and model labels remain readable.
- [ ] In both pane Chat and First Mate, verify multiline scrolling, undo/redo, Return to send, all modified-Return newline variants, Paste code, and Command-Shift-V.
- [ ] Attach by picker and drop; verify uploading, success, failure, retry, removal, attachment-only send, and that any failed selected file blocks send.
- [ ] Record a voice note; exercise hold, lock, finish, too-short, transcription success, and transcription failure.
- [ ] Quote text and code from each of the latest three completed assistant messages. Confirm older and user messages copy but do not quote, Save does not send, and quote-only send serializes inline.
- [ ] Switch features and hosts while upload, transcription, send, catalog load, confirmation, and settings save are suspended. Confirm no completion mutates the new destination and every original draft survives.
- [ ] Fail a send after acceptance is uncertain, edit the draft and add another file, then retry. Confirm the request ID is reused and success removes only the originally sent identities.
- [ ] Confirm First Mate never displays terminal keys, `/reload`, compact, workspace file, Jira, skill, or pane-conversation controls.
- [ ] Render context values for zero, unknown, unavailable, malformed, foreign session, rollover, near-threshold, and old-server states. Confirm no cumulative usage is labeled as context.
- [ ] On an established session, verify the cost warning for both model and thinking changes, cancel, confirm, stale session, stale settings revision, active owner, queued work, and idempotent retry.
- [ ] With an older server, confirm chat remains usable while attachments/context/safe settings show honest update guidance and no unsupported request fields are sent.
- [ ] With VoiceOver, verify named Attach, Voice, More, Send, retry/remove, quote, copy, model/thinking, context, and confirmation controls in a logical order.

These items are a release-gate checklist, not claims of execution. Record exact-source automated and manual evidence in the delivery report after the final gate.

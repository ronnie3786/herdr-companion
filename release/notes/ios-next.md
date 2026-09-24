# iOS next (unreleased)

## Compaction completion in Pi chats

- After Pi confirms context compaction, the composer status area replaces its compacting spinner with a checkmark and **Context compacted** beside a readiness line.
- The readiness line says **Ready for your next message.** when the session is connected and idle, describes the available **Steer** and **Follow-up** modes while Pi is still working, and says **Pi is offline. Reconnect before sending a message.** when it is not.
- Manual, automatic-threshold, and overflow compactions all show the cue, including when no assistant reply follows.
- The cue stays while a draft is typed and after a failed send. The next accepted message dismisses only the composer cue; the transcript's **Context compacted** notice remains. Starting another compaction, changing sessions, or switching branches removes the cue.
- Cancellation, failure, settlement, disconnection, or a timeout never shows a completed cue. An already-compacted chat reconstructs the fact from its saved compaction entries, and no cue is guessed from token counts, elapsed time, or a disappearing spinner.
- The row wraps at large Dynamic Type sizes, keeps the 44-point composer status height, and carries a combined VoiceOver label; color is never the only signal.

## Compatibility and delivery

No companion server, Mac app, Car mode, Pi extension, authentication, navigation,
or API contract change is required. The existing `session_compact` events and
compaction entries are sufficient; a server that provides neither simply shows
no completion cue. The signed Mac update feed installs only the Mac app, so the
iPhone/iPad build ships separately through its own pipeline.

The iOS unit suites cover the reducer, store recovery, composer configuration,
timeline placement, submission guards, and unsent-draft preservation, plus
hosted synthetic renders for progress, completed-idle, completed-working, and
offline states at narrow iPhone and iPad widths with accessibility Dynamic Type.
Those hosted renders are layout evidence, not installed-device smoke tests.
Final validation, signing, and publication belong to the reviewed release gate.

See [cross-client behavior and verification](../../docs/compaction-indicators.md).

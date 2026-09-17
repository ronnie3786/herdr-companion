# Companion 0.17.0 Preview 1

## Restricted response-brief profile

- Advertise `response-brief-v1` for the matching Mac response-brief experiment.
- Run each brief as a fresh, one-shot, tools-disabled Pi request with explicit source-session lineage. The profile rejects continuation, promotion, attachments, system-prompt overrides, invalid parent identities, and oversized output.
- Accept the exact target answer plus bounded recent context under the version 1 schema. Target text is never silently truncated; optional recent context is removed first when necessary.
- Preserve durable request receipts and terminal provider errors so reconnecting clients can observe accepted work without duplicate submission or stale replay.

The Mac user must choose the independent helper model and thinking level before enabling **Create briefs for this chat**. Brief output is generated text, while comparison-table, code, and other detail actions resolve only to exact ranges of the locally retained original. The complete unchanged original remains available in the Mac app.

## Matching components required

Install companion **0.17.0b1 or later** on every machine that hosts a source chat where response briefs will be enabled. The Mac app checks that machine for `response-brief-v1`; a stale backend receives an upgrade message and no generic or action-enabled fallback.

The signed Mac updater does not install this wheel, update packaged CLIs or Pi extensions, switch services, or restart a companion. Publishing this package does not authorize or perform a live server cutover.

## Upgrade safely

Follow the documented [server update procedure](https://github.com/ronnie3786/herdr-companion/blob/companion-v0.17.0-beta.1/herdr_harness/README.md#update-the-server):

1. Back up the state with SQLite-aware procedures and preserve the private configuration, credentials, terminal socket settings, and current rollback environment.
2. Install the released wheel into a new versioned environment rather than overwriting the active runtime.
3. Verify packaged resources, configuration, startup, authentication, and advertised capabilities from that new environment.
4. Explicitly switch only the intended companion service after verification, keeping the previous environment available for rollback.

## User-run real-chat check

After both components are installed, ask a selected chat for a harmless response containing a small comparison table, a short code block, and a caveat. In the Mac brief rail, choose the helper model and thinking level before enabling the chat. Verify the card, verbatim table/code detail links, and full unchanged original; then send another turn and confirm automatic generation. A different chat and a new `/new` session must remain opted out, and turning the feature off must stop new scheduling. This release validation does not require an agent-operated paid model call or captured real transcript.

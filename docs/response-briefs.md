# 30-second response briefs on Mac

Response briefs are an experimental, per-chat reading aid for completed Pi answers. They do not replace the original timeline or composer. On wide windows, use the quiet **Show brief** / **Hide brief** control; the app never imposes a permanent rail and places it immediately beside the preserved 980-point reading column, leaving any extra-wide surplus after the grouped reader and rail. **Open brief** presents the same rail as a closable sheet in narrower windows. Rail visibility is independent of per-chat generation opt-in.

## Setup and use

1. Install matching Mac and companion-server revisions. The server must advertise the restricted `response-brief-v1` profile from `GET /api/v1/agent-runs/capabilities`.
2. Open a native Pi chat on Mac.
3. Choose the brief model and thinking level in the rail before enabling. These controls are local to the experiment and do not alter the source chat's model or thinking setting.
4. Choose **Create briefs for this chat** in the right rail (Shift-Command-B). The opt-in immediately processes the latest completed answer using that configuration and applies only to the actual Pi session ID. `/new` creates a new identity and starts opted out.
5. Read the newest card or choose an earlier generated card from **Generated source**. The rail follows newly generated records unless you pin a prior one, and response IDs distinguish pending/latest and prior sources. Descriptive detail actions open exact line slices from the locally retained original. **Full latest original response** (Shift-Command-O) remains the actual latest source during generation or failure; a pinned card also offers **Full selected prior original**.

Turning the feature off prevents new requests and asks the server to cancel work owned by the brief coordinator. An uncertain or failed cancellation stays visible for reconciliation; it is not reported as stopped. This does not stop, resume, or otherwise modify the source Pi session. Older servers show an upgrade requirement; the app never falls back to a generic or action-enabled agent run. After updating a companion, use **Reload brief support and models** from the brief controls.

For the 0.17.0 preview, each machine hosting a selected source chat needs companion **0.17.0b1 or later** advertising `response-brief-v1`. The signed Mac updater does not install that package or switch/restart a companion service. Upgrade the server in a new versioned environment, retain a SQLite-aware state backup and rollback environment, verify the package and private configuration, and explicitly switch only the intended service after verification. Do not overwrite the active runtime in place.

### User-run real-chat smoke test

A user can exercise the feature without sharing a captured transcript. Ask Pi for a harmless response such as:

> Compare arrays and sets in a small Markdown table, then include a short Swift code example that removes duplicates. End with one caveat about preserving order.

Use **Show brief**, or **Open brief** at a narrow width. Choose the helper model and thinking level before selecting **Create briefs for this chat**; that action starts the first additional model request. Confirm that the card offers descriptive comparison-table and code details, that each detail shows verbatim lines from the original, and that **Full latest original response** shows the complete unchanged answer. Send one more message to confirm automatic generation. A different chat and a session created with `/new` must remain opted out. **Turn off for this chat** must prevent later completions from being scheduled. Against a stale companion, the app must show the upgrade requirement and make no generic or action-enabled request. Live paid calls are user-initiated, not part of automated release validation.

## What is sent

Opting in makes an additional private Pi model request for each newly completed final answer while the Mac app is running. The request contains:

- the full, exact target assistant response, carried as required `text.v1` items with the server-defined ordered labels and split only at UTF-8-safe transport boundaries;
- the current user message when it fits;
- at most the previous completed user/assistant exchange when it fits; and
- the source Pi session ID as lineage metadata.

Thinking, tool calls/results, intermediate commentary, attachments, and older conversation history are excluded. If the final assistant message has several text parts, their raw contents are concatenated in message order with no trimming or inserted separator. Recent context uses explicit optional priority and is dropped before the target; the previous user/assistant exchange is retained or omitted as one unit, while the current user message is considered independently. The rail discloses any omission. The full target is never silently truncated: if the bounded 64 KiB request cannot contain it, the rail shows a size-limit state and keeps the original available.

Enabling a chat processes only its latest completed answer, then future completions. It does not backfill the transcript. The app polls only opted-in chats (up to 20), with one generation per chat and a small global concurrency limit, so selecting another pane does not lose a completion.

## Safety and storage

The server profile runs a fresh private, tools-disabled Pi session. Generated JSON is treated as untrusted data and must match the version 1 schema exactly. The client enforces field counts, lengths, a 140-word summary limit, output size, supported detail kinds, and valid inclusive line ranges before display.

Generated titles, summaries, points, and detail labels are native plain text—not Markdown, HTML, JavaScript, or model-provided URLs. Detail bodies are extracted from the immutable local source by LF line range. The detail sheet can show rendered Markdown or selectable raw text, and **Copy exact source** copies without trimming.

Opt-in identities and model choices are metadata in local preferences. Response text, parsed briefs, and durable request receipts live in an owner-private Application Support cache (directory mode 0700, file mode 0600), limited to 40 displayed records and 4 MiB. Unresolved request receipts are never evicted just to make room. Corrupt or unreadable storage blocks generation rather than risking duplicate model calls.

**Brief actions → Clear private brief cache** asks for destructive confirmation and refuses while runs remain unresolved. It removes displayed briefs and their cached originals, but retains the small attempt ledger and response baseline so clearing does not generate old answers again. Those safety records also count toward the storage limit; reaching it blocks further generation visibly rather than silently forgetting request ownership.

## First-experiment limits

- Mac only; no cross-device synchronization.
- Brief generation needs a connected matching companion and an available selected model. A selected unavailable model is surfaced as an error rather than silently substituted.
- Invalid model JSON is not automatically regenerated. Use **Retry brief** for an uncertain transport receipt or **Regenerate latest** for a new explicit request.
- Detail references use LF line numbering. CR bytes in CRLF source and empty lines are retained exactly.
- The coordinator runs while the Mac app process is running. It does not discover new completions after the app quits. Accepted runs retain durable request receipts and can resume observation without repeating the submission.
- The waiting queue itself is in memory. If the app quits while several briefs are waiting to be submitted, those unsubmitted entries may be skipped on reopening. This first experiment does not promise a durable background queue; the Pi originals remain available and **Regenerate latest response** is explicit recovery for the latest answer.
- Generation has a two-minute client deadline. A submission that is still awaiting its server receipt remains visibly unresolved until its run ID can be reconciled; the app does not claim cancellation succeeded without confirmation.
- A summary may still omit nuance or choose an unhelpful detail range. Verbatim extraction guarantees the detail text was not rewritten, not that the summary is infallible.

## Research basis

The rail follows progressive-disclosure guidance: a compact orientation first, descriptive actions into one secondary reading surface, and no nested disclosure. See Nielsen Norman Group, [Progressive Disclosure](https://www.nngroup.com/articles/progressive-disclosure/). Apple's Human Interface Guidelines for popovers and panels informed the choice to use a readable sheet for long source, tables, and code rather than a nested transient popover.

## Verification

Use synthetic conversations only. Required final-gate coverage includes:

- exact source selection across thinking, tools, failures, aborts, and agent-settled transitions;
- previous/current exchange boundaries and UTF-8 chunk reconstruction, including CRLF, empty lines, fences, tables, and multibyte text;
- malformed, oversized, unknown-key, invalid-kind, overlong, over-140-word, and out-of-range output rejection;
- per-session opt-in and `/new` reset, deduplication, stale machine/session/source/model rejection, disable/cancel, and durable receipt replay;
- wide rail and narrow sheet rendering at normal and larger text sizes, keyboard access, VoiceOver labels, and Reduce Motion; and
- the repository's Mac unit target and public-source scan from the reviewed candidate revision.

No verification should invoke a live paid model or include a captured real session.

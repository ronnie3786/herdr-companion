# Concise response briefs on Mac

Response briefs are an experimental, per-chat reading aid for completed Pi answers. They do not replace the original timeline or composer. On wide windows, **Show brief** opens a native rail beside the preserved reading column. **Open brief** presents the same content in a sheet on narrower windows. Visibility, per-chat generation opt-in, and the app-wide length preset remain separate.

## Setup and use

1. Install matching Mac and companion-server revisions. The server must advertise `response-brief-v1` from `GET /api/v1/agent-runs/capabilities`. Configurable length additionally requires the additive `responseBriefs.lengthPolicyVersion` 2 capability with `lengthOptions`; the current Mac always sends its app-wide preset (Minimal by default), so a companion that only advertises `response-brief-v1` shows an upgrade notice for new requests and can only finish or reconcile already accepted legacy work.
2. Open a native Pi chat on Mac.
3. Choose the brief model and thinking level before enabling. These controls do not alter the source chat. Choose **Length** independently: **Minimal**, **Medium**, or **Long**.
4. Choose **Create briefs for this chat** (Shift-Command-B). This starts an additional model request for each eligible completed answer, including very short ones.
5. Read the direct takeaway, optional single caveat, and up to two descriptive links to exact source slices. **Full latest original response** (Shift-Command-O) always opens the unmodified answer.

A completed original answer is eligible whenever it contains any non-whitespace text. There is no minimum output length: the summary may be one word when the answer warrants it, and generated content is never padded, repeated, or truncated to reach a target. A short answer's allowance is an upper bound, not a target and not a minimum. Empty or whitespace-only messages, streaming answers, failed or aborted conclusions, tool-only conclusions, thinking, user messages, and older history remain outside the source contract. Newly eligible answers generate once; upgrading does not backfill history that an earlier revision skipped.

### Length presets

**Length** is one app-wide preference for this Mac, stored independently of per-chat opt-in, model, and thinking. Minimal is the default and the safe fallback when no value is stored or the stored value is unreadable. Choose a preset in the rail's `Length · …` menu; it applies to every chat on this Mac and to future requests. Changing it regenerates the brief for the source currently selected in the rail, or the latest completed source when no prior brief is selected. Re-selecting the current value does nothing, changing length does not regenerate other chats or historical records, and returning to a previously used preset still creates a deliberate fresh generation.

An accepted request finishes or reconciles under its captured preset before its replacement starts; unsubmitted length-change requests coalesce to the latest selection, and a replacement superseded during asynchronous preflight is revalidated atomically so it can never create a paid submission. Selection and cancellation ordering is persisted atomically with a per-chat revision, so a delayed older intent write can never replace or resurrect the newest selection and a relaunch behind accepted ownership resumes only the newest authorized intent. Requests that are still in flight, transport-uncertain, or waiting for relaunch retain their durable receipt and are never discarded to make a length change take effect. A transport-uncertain receipt stays visible with **Retry brief** after relaunch instead of hiding behind an idle rail. **Retry brief** and **Reload brief support and models** both resume the single queued replacement for the current selection under its captured preset instead of starting an ordinary duplicate that the intent would pay for again, and a replacement superseded by disabling the chat is removed rather than resumed after re-enabling. Turning the feature off prevents new requests and asks the server to cancel work owned by the brief coordinator. An uncertain cancellation remains visible for reconciliation. It never modifies the source Pi session. Older servers show an upgrade requirement; there is no generic-agent fallback. After updating a companion, choose **Reload brief support and models**.

The Mac app updater installs only the Mac app. Updating it does not install, upgrade, or restart a companion server, so install the matching companion revision separately on every machine where briefs are enabled. The complete preset behavior needs both sides; a Mac-only update leaves an old companion serving legacy budgets and shows the upgrade notice instead of a silently ignored setting.

### Synthetic smoke test

Use a fictional answer with a table, a small code block, and one caveat. Confirm that the default card shows one takeaway, no generated heading, at most one caveat, and at most two short detail links. The table and code should remain behind exact-source links rather than becoming prose inventories. Confirm that the complete original is unchanged, the source identity appears only from **Brief actions → Source information**, a one-character or emoji-only follow-up answer generates its own brief once, and **Regenerate latest response** creates a fresh request after a rejected generated result. Switch among Minimal, Medium, and Long and confirm that the visible ceiling grows while a genuinely short answer stays short without filler.

Live paid calls are user-initiated and are not part of automated verification.

## What is sent

Opting in permits one additional private Pi model request for each newly completed answer that needs a brief. A request contains:

- the full exact assistant response in required, ordered `text.v1` parts;
- the current user message when it fits;
- at most the previous completed user/assistant exchange when it fits; and
- the source Pi session ID as lineage metadata.

Thinking, tools, intermediate commentary, attachments, and older history are excluded. Optional context is removed before any target content. The bounded 64 KiB envelope never silently truncates the original.

Requests that include an explicit length selection carry the additive top-level `responseBriefLength` field and use a preset-aware prompt that keeps a short answer short and relies on the trusted budgets. The server charter states that any nonempty summary is acceptable and no minimum length exists. Legacy receipts and older clients that omit the field keep the pre-preset prompt byte-for-byte, so saved work replays exactly. The server validates the selection before claiming durable ownership, computes trusted numeric budgets only from required source parts, and adds them to its system charter. Source and recent-context text remain untrusted stdin data and cannot become system instructions. Tools stay disabled.

## Length presets and concision policy

Let `m` be the preset multiplier: Minimal 1, Medium 2, Long 3. All content visible on the default card—summary, point text, and detail labels together—is limited by both trusted ceilings:

- total visible non-whitespace Unicode scalars at most `m * max(40, min(240, floor(readableCharacters / 4)))`; and
- total visible words containing a Unicode letter or number at most `m * (sourceWords < 40 ? 40 : min(40, floor(sourceWords / 4)))`.

The resulting absolute ceilings are 40 words and 240 scalars for Minimal, 80 words and 480 scalars for Medium, and 120 words and 720 scalars for Long. Minimal keeps the pre-preset budget at or above 160 readable characters; the `max(40, …)` minimum gives newly eligible short sources a usable nonempty allowance without imposing a minimum on generated text. The value is a maximum: a one-character answer can legitimately produce a one-word summary.

Source readable-character counting uses Unicode letters and numbers after conservatively removing Markdown image syntax, balanced inline-link destinations, reference IDs, HTML comments, and tags (including multiline attributes). This prevents hidden syntax from inflating the allowance. The output character count includes punctuation and emoji. CRLF and combining marks are handled consistently by matching Swift and Python implementations. The count is intentionally conservative; it is a structural reduction guarantee, not a semantic-quality proof.

The summary leads with the answer or outcome. Its length follows the source and the selected preset; there is no word or character target, no 12–20-word guidance, and no padding to appear substantial. There can be only one additional point, at most 12 words, for an indispensable non-repeated caveat, blocker, or decision. There can be up to two detail labels, each at most four words and 28 non-whitespace scalars. Critical qualifications cannot be hidden behind a detail link. No field is truncated or ellipsized to pass validation. Legacy requests keep their historical 140-word request prompt and legacy ceilings because their receipts replay unchanged; preset-aware requests drop those superseded caps and rely on the captured trusted budgets.

The generated title remains in the version-1 JSON for compatibility but is not displayed or counted as visible card content. Tables, lists, code, and status inventories should remain exact-source destinations, not rewritten prose.

## Validation, cache, and recovery

The client validates new output before storage and rechecks every cached record before presentation. Each new record captures the length preset and policy version it was generated under, and both validation and presentation use that captured policy rather than whichever preset is selected later. A verbose predecessor record remains selectable in private history but is represented only by a compact regenerate-needed state; the card itself never draws its generated text. It is not deleted and does not trigger an automatic paid backfill. A single prior record remains selectable when the latest answer is short or still waiting, but default-follow-latest never substitutes that older card for the latest answer. Regeneration and original-source actions stay bound to the explicitly selected source. Presentation uses the same verified equivalence as ownership, so a reconciled live projection of the latest answer stays labeled and treated as Latest rather than as a prior source.

Malformed, oversized, unknown-key, invalid-kind, over-budget, and out-of-range output is rejected. A completed invalid result is settled once and is not automatically retried or fetched again. **Regenerate latest response** creates a fresh request, and a settled failure without a stored brief keeps that explicit regeneration control available so **Retry brief** never clears into an empty rail with no way forward. Transport-uncertain ownership continues to use durable receipt reconciliation. Legacy receipts decode without captured length metadata and replay their exact legacy payloads; existing records and attempt ledgers prevent an upgrade from replaying accepted work.

### Baseline identity and recovery

Each chat keeps a durable high-watermark for the last processed completed answer, plus baseline anchors and verified aliases. The warning **Some completed responses could not be matched to the saved brief baseline. No historical backfill was started.** comes from the coordinator's source observation when the saved response cursor cannot be found in the current conversation snapshot. A code-supported path is an answer observed while live and later persisted under a different identifier: the conversation reducer synthesizes a temporary identifier for a live block that has none, while persisted entries use their stored entry identifier, so a baseline captured before persistence can name an ID the later snapshot no longer contains. Truncated or changed history can also omit the baseline. The warning text alone does not establish which transition caused any particular session, so the client reconciles only when continuity is provable and otherwise keeps the warning actionable.

Continuity is proven only by an exact identifier, a previously recorded verified alias, or identity evidence: the exact SHA-256 content hash of the answer plus its real completed-message timestamp, corroborated by the matching user turn (timestamp or exact content). Display text, labels, ordering, and screenshot identities never reconcile responses on their own, and zero or several ambiguous candidates are left unmatched rather than guessed. A verified live-to-persisted transition records an alias, advances the durable high-watermark atomically, and continues without another paid submission or a duplicate record; a warning left by an earlier ambiguous snapshot is cleared as soon as continuity is proven.

When the baseline genuinely cannot be matched, **Restart briefs from latest response** opens a confirmation for **Restart from latest**. The confirmed action resumes accepted receipt reconciliation and explicitly replays the exact saved request for a transport-uncertain receipt before anything else runs. It then establishes a durable new baseline at the latest completed response and queues that answer once behind any ownership still settling. The latest-only recovery intent is saved in the same atomic write as the new baseline, so a relaunch while an earlier receipt is still reconciling still performs exactly one latest submission. It never backfills or replays the unmatched older history, and retry alone does not repair an unmatched cursor. Cache clearing deliberately preserves the high-watermark, anchors, aliases, and replay ownership, so clearing records does not trigger a paid backfill.

Response text, parsed records, receipts, attempt ledger, baseline anchors, verified aliases, pending regeneration intents, and the response high-watermark remain in the owner-private Application Support cache (directory mode 0700, file mode 0600), bounded to 40 displayed records and 4 MiB. Unresolved receipts are never evicted to make room.

## Compatibility

The length contract is additive. `responseBriefLength` is accepted only by the `response-brief-v1` profile, and older clients that omit it keep the legacy prompt, budgets, and payloads byte-for-byte. The companion advertises `responseBriefs.lengthPolicyVersion` and `lengthOptions`; a new Mac requires version 2 with all three options before sending any new-policy request, and every new request carries the current app-wide preset. A server that advertises only `response-brief-v1` shows **Update the companion for configurable brief length…** with a **Retry after updating** action for new work; the request is not sent, no generic-agent fallback is used, and the stored preference remains available for the retry. Existing accepted legacy runs remain reconcilable against either server revision.

Updating only the Mac app does not install or restart the companion server. Install and restart a companion revision that advertises the length capability on each machine where briefs are enabled, then choose **Reload brief support and models** in the rail.

## First-experiment limits

- Mac only; no cross-device synchronization.
- Generation requires a connected matching companion and an available selected model.
- Detail references use inclusive LF line ranges; CR bytes and empty lines remain exact.
- The coordinator runs while the Mac app is running. Accepted runs can resume from durable receipts without another submission.
- The in-memory waiting queue is bounded. The original always remains available.
- Generation has a two-minute client deadline; uncertain cancellation remains owned and visible.
- Concision and verbatim detail extraction do not guarantee a factually complete summary.

## Verification

The required **Verify** workflow at the exact candidate SHA is the authoritative automated matrix. Its portable job runs `python -m unittest discover -s tests` (including `tests.test_response_briefs`, `tests.test_assistant`, `tests.test_agent_runs`, and `tests.test_herdr_http`), the Pi and web suites, the staged public-source privacy scan, the standalone wheel install, and the credential history scan. Its Mac job runs the complete `herdr-harness-macTests` target with `xcodebuild … -only-testing:herdr-harness-macTests`, which owns the `ResponseBrief*` Swift regressions. The shared `tests/fixtures/response_brief_lengths.json` corpus pins the Swift and Python preset budgets for the same synthetic sources.

A delivery validator reviews the synthetic `ResponseBriefRenderTests` artifacts (wide rail, narrow sheet, and large-text layouts) and works through [MANUAL_TEST_CHECKLIST.md](../herdr-harness-mac/MANUAL_TEST_CHECKLIST.md); it does not duplicate the full suite locally. The checklist covers live-to-snapshot refresh, tiny answers, each preset, selected prior-source regeneration, relaunch, older-server messaging, baseline recovery, and wide/narrow large-text presentation. No check invokes a paid model, and none of these checks deploy a server or install an app.

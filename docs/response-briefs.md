# Concise response briefs on Mac

Response briefs are an experimental, per-chat reading aid for completed Pi answers. They do not replace the original timeline or composer. On wide windows, **Show brief** opens a native rail beside the preserved reading column. **Open brief** presents the same content in a sheet on narrower windows. Visibility and per-chat generation opt-in remain separate.

## Setup and use

1. Install matching Mac and companion-server revisions. The server must advertise `response-brief-v1` from `GET /api/v1/agent-runs/capabilities`.
2. Open a native Pi chat on Mac.
3. Choose the brief model and thinking level before enabling. These controls do not alter the source chat.
4. Choose **Create briefs for this chat** (Shift-Command-B). This starts an additional model request only when the latest completed answer is long enough to benefit.
5. Read the direct takeaway, optional single caveat, and up to two descriptive links to exact source slices. **Full latest original response** (Shift-Command-O) always opens the unmodified answer.

The app does not request a brief when the original has at most 160 readable letter/number scalars, including whitespace- or punctuation-only output. It quietly identifies that original as already concise. Existing accepted request receipts are still reconciled before this decision, so an upgrade cannot strand or replay paid work. Newly completed short answers advance the saved response baseline and remain skipped after relaunch.

Turning the feature off prevents new requests and asks the server to cancel work owned by the brief coordinator. An uncertain cancellation remains visible for reconciliation. It never modifies the source Pi session. Older servers show an upgrade requirement; there is no generic-agent fallback. After updating a companion, choose **Reload brief support and models**.

For the 0.18.2 preview, install the matching Mac app and companion **0.18.2b1** on each machine where briefs are enabled. The schema, `response-brief-v1` profile, request prompt, template version, and receipt identity remain version 1 for compatibility, but an older server can produce a verbose brief that the current Mac declines to present. Updating only the Mac does not install or restart the companion server. Response briefs were introduced in the 0.17.0 preview; both components now need this refinement for the complete concise behavior.

### Synthetic smoke test

Use a fictional answer with a table, a small code block, and one caveat. Confirm that the default card shows one takeaway, no generated heading, at most one caveat, and at most two short detail links. The table and code should remain behind exact-source links rather than becoming prose inventories. Confirm that the complete original is unchanged, the source identity appears only from **Brief actions → Source information**, a short follow-up answer causes no request, and **Regenerate latest response** creates a fresh request after a rejected generated result.

Live paid calls are user-initiated and are not part of automated verification.

## What is sent

Opting in permits one additional private Pi model request for each newly completed answer that needs a brief. A request contains:

- the full exact assistant response in required, ordered `text.v1` parts;
- the current user message when it fits;
- at most the previous completed user/assistant exchange when it fits; and
- the source Pi session ID as lineage metadata.

Thinking, tools, intermediate commentary, attachments, and older history are excluded. Optional context is removed before any target content. The bounded 64 KiB envelope never silently truncates the original.

The server computes trusted numeric budgets only from required source parts and adds them to its system charter. Source and recent-context text remain untrusted stdin data and cannot become system instructions. Tools stay disabled.

## Concision policy

All generated content visible on the default card—summary, point text, and detail labels together—must satisfy both limits:

- at most 40 whitespace-delimited words containing a Unicode letter or number; for sources with at least 40 words the exact ceiling is `min(40, floor(source words / 4))`; and
- at most `min(240, floor(source readable characters / 4))` non-whitespace Unicode scalars.

Source readable-character counting uses Unicode letters and numbers after conservatively removing Markdown image syntax, balanced inline-link destinations, reference IDs, HTML comments, and tags (including multiline attributes). This prevents hidden syntax from inflating the allowance. The output character count includes punctuation and emoji. CRLF and combining marks are handled consistently by matching Swift and Python implementations. The count is intentionally conservative; it is a structural reduction guarantee, not a semantic-quality proof.

The summary leads with the answer or outcome and is normally one sentence. Long sources usually need about 12–20 summary words, but that is guidance rather than a target. There can be only one additional point, at most 12 words, for an indispensable non-repeated caveat, blocker, or decision. There can be up to two detail labels, each at most four words and 28 non-whitespace scalars. Critical qualifications cannot be hidden behind a detail link. No field is truncated or ellipsized to pass validation.

The generated title remains in the version-1 JSON for compatibility but is not displayed or counted as visible card content. Tables, lists, code, and status inventories should remain exact-source destinations, not rewritten prose.

## Validation, cache, and recovery

The client validates new output before storage and rechecks every cached record before presentation. A verbose predecessor record remains selectable in private history but is represented only by a compact regenerate-needed state; the card itself never draws its generated text. It is not deleted and does not trigger an automatic paid backfill. A single prior record remains selectable when the latest answer is concise or still waiting, but default-follow-latest never substitutes that older card for the latest answer. Regeneration and original-source actions stay bound to the explicitly selected source.

Malformed, oversized, unknown-key, invalid-kind, over-budget, and out-of-range output is rejected. A completed invalid result is settled once and is not automatically retried or fetched again. **Regenerate latest response** creates a fresh request. Transport-uncertain ownership continues to use durable receipt reconciliation.

Response text, parsed records, receipts, attempt ledger, and response baseline remain in the owner-private Application Support cache (directory mode 0700, file mode 0600), bounded to 40 displayed records and 4 MiB. Unresolved receipts are never evicted to make room. Cache clearing preserves replay ownership and source high-watermarks.

## First-experiment limits

- Mac only; no cross-device synchronization.
- Generation requires a connected matching companion and an available selected model.
- Detail references use inclusive LF line ranges; CR bytes and empty lines remain exact.
- The coordinator runs while the Mac app is running. Accepted runs can resume from durable receipts without another submission.
- The in-memory waiting queue is bounded. The original always remains available.
- Generation has a two-minute client deadline; uncertain cancellation remains owned and visible.
- Concision and verbatim detail extraction do not guarantee a factually complete summary.

## Verification

Use synthetic content only. The final gate covers shared Swift/Python policy fixtures; quarter and absolute boundaries; Markdown, links, CRLF, combining marks, punctuation, emoji, and non-ASCII text; total point/label budgets; malformed/schema/range/size defenses; short-source relaunch and receipt reconciliation; cached verbose suppression; fresh explicit regeneration; compact wide and narrow/large-text renders; exact detail extraction; complete Mac unit tests; scoped Python regressions; and the public-source privacy scan. No check invokes a paid model.

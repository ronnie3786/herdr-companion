# Design: response briefs that reduce reading

## Product intent

A response brief is an optional reading aid beside a completed Pi answer, not another agent answering the task. The original remains intact and authoritative. Success means the default card is structurally much shorter than the source, gives the direct outcome first, preserves one indispensable qualification when needed, and makes exact evidence easy to open.

Short answers need no second rendition. Tables, lists, code, and status rows should not be converted into another prose inventory.

## Chosen interaction

```text
Original conversation                         Concise brief · Experimental
──────────────────────────────────────────    ────────────────────────────
User's question                               Direct answer or outcome.

Agent's complete response                     • One necessary caveat
…
…                                             View comparison table  ↗
                                              See implementation code ↗

                                              Full original response
──────────────────────────────────────────    ────────────────────────────
Existing composer stays in place.
```

- **Opt in per actual Pi session.** A new session in the same pane starts opted out.
- **Keep model controls available before opt-in.** They belong to the experiment, not the source chat.
- **Use spare horizontal space.** The rail sits beyond the established reading column. Narrow windows use an explicit sheet.
- **Two levels only.** Brief → exact original detail. No nested summaries or accordion trees.
- **One direct takeaway.** The generated title remains in the wire schema but is not repeated in the card.
- **At most one caveat.** It must add indispensable information rather than rephrase the takeaway.
- **At most two descriptive links.** Optional evidence, code, and tables can live behind exact-source links; critical qualifications cannot.
- **Quiet completed state.** Persistent first-use disclosure recedes after opt-in. Raw response identifiers appear only from Source information and accessibility/help text.
- **Stable prior selection.** A pinned prior brief remains visibly prior. Default-follow-latest does not show an old card as though it summarized a newly skipped answer.

## Deterministic reduction contract

The version-1 JSON shape remains unchanged for compatibility:

1. `title`: short compatibility label, retained but not shown.
2. `summary`: direct answer/outcome, normally one sentence.
3. `points`: zero or one indispensable caveat/blocker/decision, at most 12 words.
4. `details`: zero to two source destinations with labels of at most four words and 28 non-whitespace Unicode scalars.
5. The app's unconditional full-original action.

Every visible generated string shares one word ceiling. It is 40 words for sources below 40 readable words; otherwise it is `min(40, floor(source words / 4))`. A counted word is a whitespace-delimited token containing at least one Unicode letter or number, so even very long sources can never authorize 41 visible words.

Visible generated content also shares a hard character ceiling:

```text
min(240, floor(source readable-character count / 4))
```

Source readable characters are Unicode letters and numbers after conservative removal of Markdown link destinations and reference IDs, image alt text/destinations, and HTML comments/tags. The scanner handles balanced nested and escaped link parentheses plus multiline tag attributes, so hidden rendered syntax cannot enlarge the allowance. Visible output counts every non-whitespace Unicode scalar, including punctuation and emoji. This prevents hidden source syntax or identifier-heavy/unspaced text from defeating the structural reduction. The implementation normalizes CRLF for policy cleanup and handles combining scalars consistently in Swift and Python. Undercounting source is safer than granting an inflated budget.

The budget is a ceiling, never a target. No truncation, ellipsis, smaller font, or line limit can make failed content pass. A summary may use fewer than the suggested 12–20 words. Repetition between summary, point, and labels is explicitly forbidden by the server charter even though semantic repetition cannot be proven by counting alone.

## Short-source behavior

A source with at most 160 readable characters—including punctuation-only output—does not start a new model request. The rail quietly says the original is already concise and keeps the full original available. The durable response cursor still advances so relaunch does not backfill the answer.

Ownership reconciliation happens first. If an older client already obtained an accepted receipt for a source now considered short, the app fetches/cancels/settles that owned run normally before returning to the quiet state. It never abandons or replays the receipt.

## Source integrity

The model returns inclusive line references into the captured original response. The app resolves them against immutable local text split only on LF. It never accepts model-generated detail bodies. CR bytes, empty lines, and the exact source remain available for raw display and copying.

This guarantees verbatim extraction, not factual infallibility. The summary can still omit nuance or choose an unhelpful range, so the original remains one action away.

## Execution and trust boundary

```text
Eligible completed response
    → exact source + bounded optional conversational context
    → response-brief-v1 on matching companion
    → trusted server-computed numeric budgets in system charter
    → fresh tools-disabled Pi session
    → strict native schema + source-relative validation
    → compact native card and exact-source sheets
```

Only required source parts contribute to trusted budgets. Source labels, response text, and recent context stay untrusted stdin JSON data. The helper is parent-linked for lineage but never resumes or steers the source conversation.

The profile, request envelope, static client prompt, template version, and receipt identity remain unchanged. That preserves old receipts and cached ownership. Older servers can still answer the same profile, but a current client may reject their verbose output. This matching-server requirement is documented rather than hidden behind a fallback or new execution profile.

## Cache and recovery

Every newly generated brief is validated before storage. Every cached brief is validated again for presentation, so old verbose cards disappear without deleting their records, exact originals, receipts, or history. No migration automatically spends another model request.

A completed invalid or overlong result reaches a dedicated regenerate-needed state. Automatic observation does not loop, and retry does not fetch the same settled invalid output. Explicit regeneration uses a fresh client request while leaving predecessor history intact. Uncertain transport receipts retain their existing replay-safe reconciliation path.

## Evaluation

Use entirely synthetic examples: a concise answer, long implementation report, fictional comparison table, blocker, recommendation with caveat, code sample, punctuation-only response, identifier-heavy response, and unspaced non-ASCII response.

Ask:

- Can the reader state the outcome after one scan?
- Is the visible generated card at most one quarter of the source by the defined counts?
- Is every visible point genuinely additional?
- Are tables/status rows absent from prose and easy to open exactly?
- Are critical caveats visible rather than hidden in details?
- Does a short answer remain the shortest reading path?
- Does explicit regeneration create a fresh request without automatic paid retries?

Structural metrics prevent the previous failure mode but do not replace human judgment about semantic quality. Real-conversation capture or telemetry requires separate authorization.

See [implementation, compatibility, and verification](response-briefs.md). This source change does not install the Mac app or deploy/restart a companion server.

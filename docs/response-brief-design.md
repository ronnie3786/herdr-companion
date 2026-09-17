# Design: the 30-second response brief

## Product intent

Offer an optional, task-aware reading aid beside a completed Pi response. It is a
second presentation of the answer, not a second agent answering the user's task.
The original conversation stays intact and authoritative.

Success means someone can understand the answer, important uncertainty, and any
next decision in about 30 seconds, then inspect the original wording without
losing their place. Short answers should become no longer, and long answers
should not become a dense collection of tiny accordions.

## Chosen interaction

```text
Original conversation                         30-second brief · Experimental
──────────────────────────────────────────    ──────────────────────────────
User's question                               Short, task-specific title

Agent's complete response                     One-sentence takeaway.
…                                             • Important outcome
…                                             • Caveat or next decision
…
                                              View comparison table  ↗
                                              Read the caveats       ↗
                                              See implementation details ↗

                                              Full original response
──────────────────────────────────────────    ──────────────────────────────
Existing composer stays in place.
```

- **Opt in per actual chat session.** Explain the additional model request and
  recent conversation context before enabling. A new Pi session is not silently
  opted in just because it occupies the same terminal pane.
- **Use spare horizontal space.** Keep the established reading width; a roughly
  360–420-point rail uses the right-hand surplus. Narrow windows get an explicit
  alternate presentation rather than squeezed prose. Responsive refinement is a
  later experiment, not a reason to compromise the wide-screen version.
- **Two levels only.** Brief → original detail. No nested summaries, nested
  popovers, or accordion trees.
- **Use descriptive actions.** “View comparison table” tells the reader what is
  behind the link; “More” or “Click here” does not.
- **Keep the brief stable.** A detail action opens a focused, scrollable native
  sheet. Tables and long code need more room than a small transient popover.
  Closing it returns to the same brief, without changing the transcript height.
- **Show provenance.** Label the brief as AI rewritten, identify the source
  response, and keep the complete original one action away. Earlier generated
  briefs remain selectable so a newer completion does not erase older context.
- **Separate preference from visibility.** Hiding the rail need not disable
  generation; disabling the experiment stops future scheduling and cancels its
  owned work. Model settings belong to the experiment, not the main agent.

## Content grammar

A versioned, validated data document drives native SwiftUI components:

1. A short title.
2. One sentence with the answer or main outcome.
3. At most four important points, with source references.
4. At most six optional original-detail destinations, typed as table, code, or
   general detail.
5. An unconditional full-original action supplied by the app.

Target 70–110 words; reject generated title/summary/points exceeding 140 words.
The target is not a quota: a simple answer may need only one sentence. Important
blockers, uncertainty, warnings, and requested user decisions must survive the
summary rather than exist only in optional details.

Generated text is plain text, not executable HTML or an unrestricted mini-site.
The model chooses content and labels; the app owns layout, interactions,
accessibility, destinations, and validation.

## Source integrity

The model returns inclusive line references into the captured original response.
The app resolves those references against its immutable original Markdown. It
never accepts model-generated text as the contents of an “original detail.”
Invalid references or malformed output produce a retry/error state, not an
invented excerpt. Copying the original uses its stored text, not reconstructed
Markdown from the rendered view.

This guarantees verbatim source excerpts, **not** a factually infallible summary:
the model can still choose an unhelpful range or omit nuance. The original remains
visible and accessible, and the interface must not imply that line references
independently verify the underlying answer.

## Execution and privacy

```text
Completed final response in an opted-in chat
    → immutable source + at most two exchanges of text context
    → authenticated companion API, response-brief-v1 capability
    → fresh, tools-disabled Pi session using the chosen model
    → bounded JSON response validation
    → native brief + locally resolved source-detail views
```

The selected model receives the original response and bounded recent user/agent
text through the existing Pi/provider configuration. Tool traces, hidden
reasoning, workspace files, and unrelated conversations are not added. Source
material is untrusted data, not a new instruction to execute.

The companion advertises the new restricted profile explicitly. An older server
shows an upgrade requirement; it never falls back to a tools-enabled agent run.
The helper is parent-linked to the source Pi session, but never resumes, steers,
or modifies that conversation.

Jobs are deduplicated using source/session/model/template identity and durable
request receipts. A detail click makes no model call. Full target responses are
never silently truncated to fit a request; an oversized response shows a limit
state with the original still available. Cached text belongs in private,
bounded Application Support storage, not preferences or operational logs.

## Evaluation after trying it

Review a small set of entirely synthetic examples first: a concise answer, a
long implementation report, a comparison table, a failure with a blocker, a
recommendation with caveats, and a response containing code. Then evaluate the
opted-in experiment on real work:

- Can the reader state the main answer and next decision after one short scan?
- Does the brief preserve uncertainty and distinguish planned from completed work?
- Do link labels predict the content they reveal?
- Are tables and exact original wording easy to find and copy?
- Is post-response latency and the extra model cost worth the reading benefit?
- Does new output remain correctly associated when switching chats or models?

Do not infer usefulness just from shorter word counts. Avoid telemetry or capture
of real conversations unless separately requested.

## Research behind the choices

- [Nielsen Norman Group: Progressive Disclosure](https://www.nngroup.com/articles/progressive-disclosure/)
  recommends a small primary surface, clearly labeled progression to secondary
  information, and generally avoiding more than two disclosure levels.
- [Apple Human Interface Guidelines: Popovers](https://developer.apple.com/design/human-interface-guidelines/popovers)
  describes popovers as transient surfaces for a small amount of information.
  This supports using a focused detail sheet for longer original text and tables.
- [Apple Human Interface Guidelines: Panels](https://developer.apple.com/design/human-interface-guidelines/panels)
  describes supplementary information tied to the active content or selection.
  The brief rail follows this inspector-like relationship rather than behaving as
  an unrelated second conversation.

Apple guidance was consulted through the locally indexed Cupertino HIG catalog;
the links above are its public counterparts. Research informs these design
choices; it is not evidence that this particular experiment has been user-tested.

See [implementation and setup](response-briefs.md) for delivered behavior,
compatibility, and limits. This source implementation does not itself install an
app update or deploy the companion server.

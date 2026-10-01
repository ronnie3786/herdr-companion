# PR review buddy

The native Mac PR Review workbench includes a coding buddy that explains a pull
request in short chapters. Open a prepared review's **Files** tab and choose
**Start walkthrough**. Existing review skills do not run again when you start a
walkthrough. **Suggested order** still controls the file list independently.

## Saved walkthroughs

A walkthrough keeps preparing on the companion after you leave the review, switch
reviews, or close the window. When it is ready, or if it fails, the Mac posts a
notification and badges **PR Review** in the navigator. The review's row shows
**Walkthrough ready** until you open it. Choose the notification to open the
review. Opening the review in the active app clears its badge on every Mac
connected to that companion.

Walkthroughs stay saved with the review. Reopening a review shows its newest
walkthrough for the current revision and comparison. A walkthrough that is still
preparing shows its progress there. Archiving a review deletes its walkthroughs,
answers, and pinned walkthrough source on the companion and this Mac's saved
place. Unarchiving does not restore them.

Notifications use Herdr's existing notification permission and never ask for
it. A banner is skipped when the review is already open in the active app. A
walkthrough that settled more than 30 minutes before the Mac reconnected only
updates the badge.

The compact dock keeps the code in view. Play an explanation, pause, replay, seek,
or change playback speed. **Next** advances the chapter only when you choose it.
Expand to read the explanation, choose a chapter, inspect sources, and revisit
questions. Completing the walkthrough does not mark files viewed or submit a
GitHub review.

Ask a question at any time, including before starting a walkthrough. Selecting
code supplies the exact selection. Questions pause the current passage and can
navigate to other changed files. **Back to walkthrough** restores the saved
chapter and passage paused. Voice capture uses the existing recorder and
transcription configuration; check the transcript before sending.

## Code and review evidence

Each request captures the PR description, a bounded patch packet, selected code,
and relevant sections of saved review documents. It uses an independent,
revision-pinned copy of committed source for the buddy's read-only tools. A
follow-up retrieves current report context again while keeping the earlier
answer intact. Retrying the same request retains its original context snapshot.

Reports remain claims to inspect. Source detail shows the original excerpt,
retained document, available reviewer attribution, and revision/provenance.
Explicit reviewer labels in reports are report assertions, not proof that a
particular agent produced the file. Shared output discovery cannot reliably
assign a nested reviewer. Unknown, historical, dismissed, or conflicting claims
must be distinguished from supported code concerns. Code inspection does not
establish that a test ran.

The first release indexes bounded Markdown and HTML sections, with exact changed
paths and unambiguous bare filenames. Unsupported media and omitted sections are
reported as coverage limits. Original documents stay available in Context.
The guide does not add a vector database or require a new review producer format.

Refreshing to a different code revision pauses the old walkthrough and leaves
its transcript readable. Start a new walkthrough to explain the current revision.
Playback and question state are owned by each review window. Your place in a
walkthrough is saved privately on the Mac; the walkthrough itself is saved on
the companion. The restricted Pi tools are a tool policy, not an operating
system filesystem sandbox.

## Narration and drawings

Narration uses the companion's existing private Kokoro service configuration.
The Mac receives audio and timing metadata through the authenticated companion;
no operator speech endpoint is bundled in the app. A captioned recording includes
its exact script, selected voice, measured duration, word timestamps, and script
and audio hashes.

Circle, underline, and arrow intentions attach to exact changed lines and spoken
phrases. Each voice compiles its own cue times. `AVAudioPlayer.currentTime` is the
single timeline for playback and drawings, including pause, seeking, replay, and
speed changes. The existing bundled WebKit diff resolves geometry, so scrolling,
font changes, and resizing keep marks attached to the rendered code. Reduce
Motion shows each completed mark at its cue onset.

A missing code target never selects a nearby line. The buddy waits briefly for
the requested surface, then keeps the explanation usable if the target cannot
render. Unavailable captions or invalid recordings leave text readable, without
inventing synchronized timing. Changing voices restarts the current passage.

## Compatibility and delivery

This feature requires a matching companion advertising `pr-review-guide-v1`,
`pr-review-context-v2`, and captioned narration support for speech. Saved
walkthroughs, background notifications, and the badge also require
`pr-review-walkthroughs-v1`. It adds `GET /api/v1/pr-reviews/{reviewId}/walkthroughs`,
`POST /api/v1/pr-reviews/{reviewId}/walkthroughs/{guideId}/seen`, a `walkthrough`
summary on each review, and the `pr_review.walkthrough` event. These are
additive APIs. Existing `pr-review-v1` clients and ordinary response audio retain
their original contracts. An older companion keeps the existing review workbench
and reports that the walkthrough requires an update.

Install the companion package separately on the review host and any other
configured servers. The signed Mac update feed installs only the Mac app. Keep
service configuration, credentials, saved review data, and prior runtimes during
server updates. See [server updates](../herdr_harness/README.md#update-the-server)
and [Mac releases](macos-releases.md).

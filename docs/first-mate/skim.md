# Skims: long replies in one breath

A skim is a second presentation of a long reply: one or two short, casual sentences
from the agent, in which dotted phrases open the exact original text. Main Mac chat,
First Mate replies (including stage results, notices, and escalations), and HUD chat answers
of at least 80 words get one. Shorter replies are shown as they are, and the full
reply is always one click away.

Requires a companion advertising `first-mate-skim-v1`. Clients without it, or
connected to an older companion, show every reply in full exactly as before.
Main Mac chat additionally requires `chat-skim-v1`. New skims use `skim-v5`.
A companion upgrade refreshes stale skims on the latest recent replies in live
First Mate and HUD conversations, within the configured backfill window. Older
histories remain readable. The signed Mac updater does not install the companion
package. Install and restart the matching companion separately using the
repository README.

## What you see

In order, in the assistant's reply:

1. **The summary**: at most about 30 words, with two to five dotted phrases.
   Its total budget, including caveat and next step, is about 20% larger than
   `skim-v3` (36 to 42 words instead of 30 to 35). Extra space keeps a useful
   reason or detail, without padding.
   Hover a phrase for a preview of what it opens: its kind, line range, and a
   snippet, or for code the language, line count, and the lines that matter.
   Click it (or Tab to it and press Return) for the original in a card: an
   **Original** tag and `Lines a–b`, **Copy** for the exact text, and **Show in
   reply**, which opens the full reply scrolled to those lines and highlighted.
   Code in the card is highlighted, never wraps, and has **Copy code** (without
   the fences). Escape or a click outside closes the card; one card is open at a
   time.
2. **A caveat**, with a rose rule, only when something failed or is risky.
3. **Rest of the original**: everything the sentence doesn't link to, each
   block with its section heading.
4. **An optional question or suggestion** after an amber dot, only when that
   complete sentence appears in the original response. Concrete offers such as
   “I can add a test if you want” and declarative next steps are supported.
   The skim never invents
   a follow-up to fill the template or turns ongoing work into an offer.
5. **Suggested reply chips**, on Mac only: zero to three options, each one to
   five words, displayed in title case. Hover a chip for a one-sentence explanation, or use its VoiceOver
   hint. Clicking sends the original offered phrase as a normal chat reply. The
   explanation is never appended as hidden input. Explicitly offered phrases
   are preserved; otherwise the model may phrase a clear next step. Informational
   answers, completed work, generic offers, and work already underway need no
   chips. Chips use the existing compact control styling and wrap at narrow widths.

Only the latest eligible reply in a live conversation can offer actions. Older
messages and read-only transcripts retain their skims. Chips are disabled while
offline, sending, or composing a draft (including attachments and quotes). Closed,
archived, and promoted destinations cannot send from an old chip. Submission uses
each surface's normal send path, rechecks the destination, prevents double clicks,
and leaves failed sends recoverable. Reply chips remain available in Full reply mode.

**Full reply** / **Skim** switches each message, and the choice is kept while
the chat is open. Copy, quotes, and response feedback always act on the full
reply. While a skim is being written the full reply shows with a quiet
"Skimming…"; the skim then swaps in without animation, but never while you have
text selected, a card open, or the pointer over that reply. A failed skim just
leaves the full reply, with no error.

On iPhone and iPad the existing skim reader is unchanged: a tap opens the original
(a sheet on iPhone, a popover on iPad). It ignores the optional reply actions.

## How it works

- When a reply is saved, the companion records a pending skim in the same write
  (First Mate: `fm_message_skims`; HUD chats: `skim.json` beside the turn), so
  clients show "Skimming…" at once. The reply itself is never delayed or changed.
- A pool of at most two workers runs one tool-free Pi inference per reply
  (profile `first-mate-skim-v1`): the packaged prompt `skim-v5` with the
  `breath_balanced` format, no tools, extensions, skills, or context files, retries
  and compaction off, in a neutral temporary workspace. Each run has a 60-second
  limit. A skim is attempted once per generation; a run cut short by a restart
  is resumed once.
- The output is Skim markup (see the Skim lab's SPEC). The companion segments the
  reply, normalizes the markup, repairs routine model mistakes, and rejects
  runaway output. A deterministic source check drops optional follow-ups that
  are not verbatim questions or suggestions from the reply, including follow-ups
  in previously saved First Mate skims. Unsupported actions do not trigger another
  inference. Excerpts are never model text: clients slice them from the
  reply they already have, using the stored segment offsets (UTF-16 code units
  into the reply with line endings as LF), and refuse a skim whose
  `reply_sha256` does not match.
- Board, snapshot, and HUD chat turn responses carry
  `skim: {status, format, prompt_version, segmenter_version, skim_version}`,
  plus `document`, `segments`, and `reply_sha256` once it is `ready`. A skim
  that lands changes the board version.
- Replies from the last 24 hours that predate the companion update are skimmed
  once in the background. Stale cached skims on the latest replies in live
  First Mate and HUD conversations refresh once for the new generation settings.
  A refresh temporarily shows the original reply; an empty list of actions does
  not trigger another attempt.
- Main Mac chat skims are prepared by the companion when Pi saves an idle
  checkpoint after `agent_settled`, even when the chat is unopened. Reconnect
  checkpoints also prepare the latest completed answer. The reader retrieves
  that same cached result through authenticated `POST /api/v1/skims` and polls
  `GET /api/v1/skims/{id}` if it is still pending. Opening older replies, or ones
  that could not fit in the background queue, remains an on-demand fallback. Streaming,
  tool commentary, cancelled, and failed turns are ineligible. The companion uses
  the same worker pool and configured model; a content-addressed private SQLite
  cache includes the reply hash, question, model settings, and prompt version in
  its identity. It retains at most 256 results and 32 pending jobs. Raw source is
  removed when a job settles. Interrupted jobs get at most one restart attempt;
  polling and input sizes are bounded, and every failure leaves the full reply.
- Optional `document.actions` entries contain `id`, `label`, `explanation`, and
  source `refs`. Invalid, duplicate, oversized, ungrounded, or code/quote-sourced
  options are omitted without discarding the summary. Options require an ask or
  next-step line. Legacy documents require no new fields.

## What the model sees

Only the reply and the human question it answers (for a HUD turn, your prompt).
Attachment paths are removed from the question, and a stage result or notice has
no question. The reply is treated as data, never as instructions. Nothing about
the machine, workspace, or feature is included, and the companion logs only ids,
statuses, and timings, never reply or skim text.

## Configure

In the private configuration's `[first_mate]` table:

| Key | Default | Meaning |
| --- | --- | --- |
| `skim` | `true` | Turn skims on or off. Turning them off fails any pending skim, so readers see full replies. |
| `skim_model` | Pi's default | A fast `provider/model`. Skims wait on this model. |
| `skim_thinking` | `low` | Pi thinking level. Don't use `off` with small thinking models; it can run away. |
| `skim_min_words` | `80` | Shorter replies are never skimmed. |
| `skim_hud_chats` | `true` | Also skim HUD chat answers. |
| `skim_backfill_hours` | `24` | How far back to skim replies that predate the update; `0` skims only new ones. |

A companion running under launchd has no login shell, so a provider key the model
needs (for example an Ollama Cloud key) belongs in the private configuration's
`[environment]` table, preferably as a `{ file = "…" }` reference to a private
secret file.

## Check the behavior

1. Ask a synthetic First Mate feature a question whose answer runs long. Expect
   the reply with "Skimming…", then the skim within a few seconds.
2. Hover each dotted phrase, then click one. The card's text must match the
   reply exactly; **Copy** copies it and **Show in reply** highlights it.
3. Switch to **Full reply** and back. Rate and quote the reply; both act on the
   full text.
4. Ask a HUD chat and main Mac chat a long question and expect the same. Streaming
   output should stay full until the turn settles. Leave a Main Chat closed while
   it finishes, allow time for the skim model, then open it: the reader should
   retrieve the completed skim without starting another model run. The matching
   companion must be installed and restarted separately for background preparation.
5. Use a synthetic reply offering “recover it” and “revise it”. Confirm title-case
   labels and the original outgoing phrases, hover explanations, keyboard activation, and one normal message per
   click. Test a draft, attachments, disconnection, a failed send, feature/session
   switching, an older response, and a completed reply with no next step.
6. Check light and dark First Mate, a narrow HUD, and the largest text scale.
7. Set `skim = false`, restart the companion, and confirm new replies show in full.

Focused regression commands:

```sh
.venv/bin/python -m unittest tests.test_skim tests.test_skim_service tests.test_skim_actions tests.test_chat_skims tests.test_pi_chat_skims tests.test_herdr_http.HerdrHTTPTests.test_chat_skims_require_authentication_and_bound_inputs
xcodebuild -project herdr-harness-mac/herdr-harness-mac.xcodeproj -scheme herdr-harness-mac -destination 'platform=macOS' test -only-testing:herdr-harness-macTests/SkimReplyTests -only-testing:herdr-harness-macTests/ChatSkimTests -only-testing:herdr-harness-macTests/SkimReplyRenderTests -only-testing:herdr-harness-macTests/FirstMateSkimTests
```

These tests use synthetic replies and a fake model. They verify the contract,
transport, rendering, and send behavior; model writing quality still depends on
the configured model following the prompt.

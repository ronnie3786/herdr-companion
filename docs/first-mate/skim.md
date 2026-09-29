# Skims: long replies in one breath

A skim is a second presentation of a long reply: one short, casual sentence from
the agent, in which a few dotted phrases open the exact original text. First Mate
replies (including stage results, notices, and escalations) and HUD chat answers
of at least 80 words get one. Shorter replies are shown as they are, and the full
reply is always one click away.

Requires a companion advertising `first-mate-skim-v1`. Clients without it, or
connected to an older companion, show every reply in full exactly as before.

## What you see

In order, under the First Mate label (or the HUD answer):

1. **The sentence**: at most about 25 words, with three to five dotted phrases.
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
   complete sentence appears in the original response. The skim never invents
   a follow-up to fill the template or turns ongoing work into an offer.

**Full reply** / **Skim** switches each message, and the choice is kept while
the chat is open. Copy, quotes, and response feedback always act on the full
reply. While a skim is being written the full reply shows with a quiet
"Skimming…"; the skim then swaps in without animation, but never while you have
text selected, a card open, or the pointer over that reply. A failed skim just
leaves the full reply, with no error.

On iPhone and iPad a tap opens the original (a sheet on iPhone, a popover on
iPad); there is no hover preview.

## How it works

- When a reply is saved, the companion records a pending skim in the same write
  (First Mate: `fm_message_skims`; HUD chats: `skim.json` beside the turn), so
  clients show "Skimming…" at once. The reply itself is never delayed or changed.
- A pool of at most two workers runs one tool-free Pi inference per reply
  (profile `first-mate-skim-v1`): the packaged prompt `skim-v3` with the
  `breath_tight` format, no tools, extensions, skills, or context files, retries
  and compaction off, in a neutral temporary workspace. Each run has a 60-second
  limit. A skim is attempted once; a run cut short by a restart is resumed once.
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
  once in the background.

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
4. Ask a HUD chat a long question and expect the same.
5. Set `skim = false`, restart the companion, and confirm replies show in full.

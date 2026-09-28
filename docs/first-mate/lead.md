# The lead First Mate

The lead First Mate is one continuing conversation across every First Mate
feature on a machine. Each feature still has its own First Mate (its "second
mate") that runs that feature's stages and workers. You ask the lead what needs
you, what a feature is doing, or what to do next, and you give it decisions to
pass on. It never begins, approves, or finishes a feature's work itself.

Requires a companion advertising `first-mate-lead-v1`. The Mac shows it as
**My First Mate** in the First Mate chat window and as the chat in the First Mate
HUD. Against an older companion both keep their earlier behavior: a briefing
built on the Mac, and local answers in the HUD.

## What it does

- **Answers across features.** "What needs me?", "What is Receipt export
  waiting on?", "What finished today?" It reads the fleet summary and one
  feature's status, recent conversation, journal, and Documents on demand.
- **Passes your decisions on.** Tell it "Use CSV for the receipt export" and it
  posts your words to that feature as your message, marks that feature's newest
  message read, and says so in one line. The feature's own First Mate replies in
  its chat. It relays only what you actually said or decided, only on your turn,
  and asks one short question when the feature or the decision is unclear.
- **Starts features** when you ask, with a goal and an existing project folder on
  that machine.
- **Uses ordinary tools.** Like a HUD chat, it has Pi's normal configured tools,
  skills, and context, working from the companion account's home folder, for
  short lookups. Real feature work is routed to the feature.

Its tools reach one machine's features. With more than one machine, the Mac
talks to the lead on the machine with the most active features (ties go to this
Mac's own companion) and remembers that choice, so the conversation stays on one
machine; choose another in the chat window header. Each message the Mac sends to
the lead also carries a small read-only snapshot of your other machines'
features (label, status, step, the "now" line, unread, and the latest message
preview), so it can answer across all of them. It cannot read further into those
or relay to them: it names the machine, and you answer in that feature's chat.

## Model, context, skims

- **Model.** The lead uses the host's First Mate coordinator model and thinking
  (`[first_mate] model` and `coordinator_thinking` in the private configuration),
  and the same per-conversation override as a feature: the model pill in its
  composer (`POST /features/{id}/model-settings`).
- **Context.** The composer's context line shows the current session's
  measurement. After a reply that reaches the handoff target (`context_target`,
  150,000 tokens by default, lowered for small model windows), the next turn
  starts a fresh Pi session that carries the recent conversation, the last 30
  messages at up to 4,000 characters each. The old session stays retained in
  full. Unlike a feature coordinator, the lead also keeps Pi's automatic
  compaction for one turn that would overflow before it can hand off.
- **Skims.** Its replies are First Mate replies, so long ones get a skim like any
  other (`[first_mate] skim_model`). See [skims](skim.md).

## API

- `GET /api/v1/first-mate/lead` returns `{ok, lead}`: null before first use, else
  `{feature, unread, working_on_reply, latest_message}`. It is one bounded read,
  cheap enough to poll.
- `POST /api/v1/first-mate/lead` with an optional `request_id` creates the lead
  on first use (201) or returns it (200). There is exactly one per ledger.
- Everything else uses the ordinary feature routes with the lead's
  `feature.id`: detail and board, `messages`, `attachments`, `model-settings`,
  `read`, and `feedback`. The lead's feature row has `kind: "lead"`.
- A message to the lead may add `context: {machines: [{name, features: [{label,
  title, status, step, now, unread, latest}]}]}`: at most 8 machines and 40
  features each, strings clipped, unknown fields dropped. It is kept in its own
  table (`fm_message_context`), shown to the lead's turn only, and never repeated
  in the conversation clients poll. Features refuse it.
- The lead never appears in `GET /features`, `GET /fleet`, notifications, or
  control discovery. It refuses archive, pause, resume, cancel, labels, and
  workflow stages.

## Tools

The lead's Pi extension registers only these First Mate tools:

| Tool | What it does |
| --- | --- |
| `fm_fleet` | Every active feature: label, status, step, now, unread, latest message |
| `fm_feature_status` | One feature's router state, recent conversation, and journal |
| `fm_read_document` | A feature's Document by ID |
| `fm_mark_read` | Marks a feature's newest First Mate message read |
| `fm_relay` | Posts the human's words to a feature as their message (human turns only) |
| `fm_create_feature` | Starts a feature with a goal and an existing absolute folder (human turns only) |

A relayed message carries `metadata.relayed_by: "lead"` and the lead message ID,
and the feature's journal records it. The runtime is
`first_mate_runtime.py` (`LEAD_PROMPT`, `_lead_tool`); storage is the `kind`
column on `fm_features` (schema 16).

## Check the behavior

1. Open the First Mate chat window on **My First Mate** and ask "What needs me?".
   Expect a short answer naming your features, and a skim when it runs long.
2. Answer a feature's open question through the lead ("Tell Receipt export to
   ship iPhone-only"). Expect a one-line confirmation here and your words, as
   your message, at the bottom of that feature's chat.
3. Click the HUD's face. The same conversation opens with the shared composer:
   attach, paste, voice, the model pill, and the context line.
4. Hold the face, ask a question, and let go. Expect "Asked First Mate" beside
   the face, then the answer there when it lands; click it to open the chat.

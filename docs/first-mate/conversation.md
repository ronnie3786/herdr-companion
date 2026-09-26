# What reaches the First Mate chat

First Mate's chat is a conversation between you and the feature's lead developer.
You give direction; First Mate answers and reports back when a stage is done, when
it needs a decision, or when it is blocked. Everything else stays in the journal,
Documents, and saved sessions, where it remains available on demand.

Requires a companion advertising `first-mate-quiet-chat-v1`. Older companions keep
their previous behavior.

## In the chat

| Message | When |
| --- | --- |
| Your direction | Every message you send. |
| First Mate's reply | Every reply to your message. |
| Stage result | When a stage closes (`fm_complete_stage`). The checkpoint names the result, the deliverable, the verification verdict, and any decision needed, then says whether First Mate is continuing to an authorized next stage or waiting for you. The summary is limited to 1,200 characters and the recommendation to 400; longer text is refused so the coordinator shortens it and leaves detail in Documents. |
| Notice | A background turn used `fm_notify_human` for a decision, a blocker, or a finished deliverable ready for your review. At most one per turn, 600 characters. |
| Escalation | A worker asked for a human checkpoint, or recovery was exhausted, and First Mate explained what it needs. Each assignment's decision gets its own message, even when several arrive together. |
| Stranded stage | A background turn ended with nothing running and nothing queued, so only you can move the stage. First Mate's closing message is delivered. If the turn itself failed, the chat says First Mate stopped and asks you to send a message to continue. |

## Not in the chat

Worker outcomes, authorized follow-ups, and stability sweeps are **background
turns**. They wake the coordinator, but its closing message becomes a private
`coordinator.note` journal event instead of a chat message. The Mac shows the most
recent notes in **Overview → Journal**, and the full text stays in the
coordinator's saved session.

A background turn never adds a second message when it already posted a stage
result or a notice. An update that is released for your message and claimed
again counts as a new turn. A delivered report records a fingerprint of the
workflow state (feature status, current stage, and each current assignment's
status, verdict, and human gate); an escalation also records the assignment it is
about. Until you send another message, a later report with the same fingerprint
is kept as a note, so a stuck stage is reported once, not once per stability
sweep.

Worker outcome updates are pointers: the verdict, a short excerpt, the assignment
ID, and Document IDs. The coordinator reads the full summary from its router state,
so the report is not copied into its conversation twice.

A background turn that fails while other work is still running stays in the
journal next to the existing `coordinator.interrupted` event. On your own turn,
you always see a reply, including a failure message.

Journal milestones such as queued, progressing, or finished workers appear in
**Overview → Journal**, not between chat messages.

## Existing conversations

When the updated companion first opens its ledger, it adds a `visibility` column to
`fm_messages` and labels history once:

- System updates are `background`.
- A reply to a worker outcome, an authorized follow-up, or a stability sweep is
  `background` when the same turn already posted a stage result, or when a later
  report followed it before you wrote again.
- A run of such replies that your next message answered stays, so a question is
  never hidden beside your answer.
- Your messages, stage results, replies to escalations, and anything the companion
  cannot classify stay in the conversation.

No message text is changed or deleted. Snapshots still include every row, with its
`visibility` field. The board, feature summaries, and updated clients show only
`conversation` rows.

## Check the behavior

1. Start a synthetic feature and ask for a plan. Expect your message, one short
   reply, and later one stage result. The planner's outcome does not appear as a
   separate message, and **Overview → Journal** shows First Mate's private note.
2. Ask for several parallel workers. Expect a single stage result after all of them
   report, not one message per worker.
3. Have a worker request a human checkpoint. Expect one message naming the
   decision.
4. Leave a stage blocked with nothing running. Expect one message asking for
   direction. Later stability sweeps stay in the journal until you reply.

# Herdr Companion 0.49.0-beta.1

## A quieter First Mate chat

First Mate's chat now reads as a conversation with the feature's lead developer:
your direction, its replies, one result per stage, and a message only when it
needs you.

- The Agent view **Chat** tab shows only the conversation. Lines for queued,
  progressing, and finished workers, advisor assessments, and other workflow
  milestones moved to **Overview → Journal**.
- Replies First Mate wrote to routine background updates (worker outcomes,
  authorized follow-ups, and stability sweeps) no longer appear in the Agent view
  or the full conversation. With an updated companion, existing conversations are
  relabeled once: stage results, escalations, and any reply you answered stay.
- First Mate's private notes from background work appear in
  **Overview → Journal**.

## iOS source included

The iPhone and iPad First Mate conversation uses the same rule: its chat shows
the conversation only, and Overview's journal shows workflow milestones and First
Mate's notes. The change is merged and tested in this source revision; this Mac
update does not install an iOS build.

## Compatibility and installation

Install this preview through **Herdr Companion → Check for Updates…**, with
**Include preview builds** enabled. The app is Apple Development-signed,
distributed through the signed update feed, and is not notarized.

The quieter conversation needs the matching companion 0.49.0b1 package with
`first-mate-quiet-chat-v1`, installed separately. That server update stops
First Mate from posting background chatter, keeps stage results short, and
labels existing history. With an older companion, the app still moves journal
lines out of the chat but cannot tell which older replies were background
chatter. The Mac updater does not install server packages, restart services, or
update iOS.

## Check the changes

- Open a First Mate feature in the Agent view. **Chat** shows your messages,
  First Mate's replies, and stage results. **Overview → Journal** shows recent
  workflow activity and First Mate's notes.
- On a disposable feature, ask for a plan with two parallel reviewers. Expect
  one reply to your message and one stage result, with no message per worker.

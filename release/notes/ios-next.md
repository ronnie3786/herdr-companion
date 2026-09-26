# iOS next (unreleased)

## All Machines in First Mate

- The **First Mate** tab opens on **All Machines**, combining the features of every configured host with items waiting for your direction first. Each combined card names its owning host, while the host menu now offers **All Machines** plus every machine individually.
- Choosing one machine filters the list to it; choosing **All Machines** restores the combined view. An explicit choice is remembered across launches, and a saved host that leaves the roster resolves to All Machines instead of another machine.
- Refresh, search, and **Show archived** apply across the hosts in scope. An offline, unsupported, or empty host shows its own notice, and cached features stay readable without hiding a healthy host's features.
- Creating a feature from All Machines requires choosing its destination host before a repository folder is accepted. A single-machine scope preselects that host, recent folders come only from the chosen destination, and changing the destination clears the previous folder.
- Opening a feature, sending direction, archiving, and reading documents or saved sessions always use the exact owning host, even when two machines share a feature ID. Detail navigation and open sheets are cleared when an owner is removed or a connection is replaced, never redirected to another machine.
- The versioned scope preference leaves the legacy `herdr.firstMate.machine` value untouched; an upgrade with only that value opens on All Machines.

## Compaction completion in Pi chats

- After Pi confirms context compaction, the composer status area replaces its compacting spinner with a checkmark and **Context compacted** beside a readiness line.
- The readiness line says **Ready for your next message.** when the session is connected and idle, describes the available **Steer** and **Follow-up** modes while Pi is still working, and says **Pi is offline. Reconnect before sending a message.** when it is not.
- Manual, automatic-threshold, and overflow compactions all show the cue, including when no assistant reply follows.
- The cue stays while a draft is typed and after a failed send. The next accepted message dismisses only the composer cue; the transcript's **Context compacted** notice remains. Starting another compaction, changing sessions, or switching branches removes the cue.
- Cancellation, failure, settlement, disconnection, or a timeout never shows a completed cue. An already-compacted chat reconstructs the fact from its saved compaction entries, and no cue is guessed from token counts, elapsed time, or a disappearing spinner.
- The row wraps at large Dynamic Type sizes, keeps the 44-point composer status height, and carries a combined VoiceOver label; color is never the only signal.

## Compatibility and delivery

No companion server, Mac app, Car mode, Pi extension, authentication, navigation,
or API contract change is required. The existing `session_compact` events and
compaction entries are sufficient; a server that provides neither simply shows
no completion cue. The All Machines First Mate behavior needs only the existing
`first-mate-v1` listing, capability, detail, resource, and mutation APIs; an
older companion keeps its own notice and does not block a healthy host. The
signed Mac update feed installs only the Mac app, so both the iPhone/iPad build
with All Machines and the existing compaction cue ship separately through the
iOS pipeline; publishing a Mac release does not install either on a phone.

The iOS unit suites cover the reducer, store recovery, composer configuration,
timeline placement, submission guards, and unsent-draft preservation, plus
hosted synthetic renders for progress, completed-idle, completed-working, and
offline states at narrow iPhone and iPad widths with accessibility Dynamic Type.
Those hosted renders are layout evidence, not installed-device smoke tests.
Final validation, signing, and publication belong to the reviewed release gate.

See [cross-client behavior and verification](../../docs/compaction-indicators.md).

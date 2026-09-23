# Pi compaction indicators on Mac and iOS

This guide describes the in-progress and completed compaction cues that Mac and
iPhone/iPad Pi chats show beside the prompt, the evidence contract behind them,
and the synthetic verification that covers both native clients. It applies to
ordinary native Pi pane chats only: First Mate coordinator chat, saved read-only
sessions, HUD agent-run chat, Car mode, and the browser client keep their
existing behavior.

## State semantics

Three independent states describe a compaction:

| State | Source | What the composer shows |
| --- | --- | --- |
| Compaction in progress | `session_before_compact`, or `isCompacting`/`compaction.active` in a connected snapshot | The existing reason-aware spinner (**Compacting context…**, automatic, or overflow/retry copy) with no prompt controls |
| Compaction confirmed | An explicit `session_compact` event or a persisted `compaction` snapshot entry | A checkmark and **Context compacted** with a readiness line; normal prompt controls return |
| Agent turn phase | `session_start`/`turn_start`/`message_*`/`agent_settled` | Working, idle, or failed; the completion cue does not change it |

The completed cue is deliberately not derived from the phase or from the
spinner disappearing: Pi can finish a compaction while an overflowed turn
resumes, so an idle session and a completed compaction are different facts.

## Evidence contract

Success is proven only by:

- an explicit `session_compact` stream event, or
- a persisted `compaction` entry in an authoritative snapshot.

The live event is captured before a recovery boundary and is published only
after the matching authoritative recovery commits. A truncated snapshot that
omits the entry uses the scoped event cursor as evidence; a snapshot that still
provides the entry deduplicates by entry identity. Nothing is inferred from
token counts, elapsed time, display text, or a disappearing spinner.

The following never produce the cue:

- `session_compact_end` with `completed`, `failed`, `aborted`, or `settled`;
- a disconnect, bridge-offline frame, or error;
- a recovery timeout or a snapshot that never reaches the compacting event's
  watermark;
- an older snapshot that still projects only a compaction superseded by a newer
  attempt.

The cue is session-scoped. Changing pane, machine, session, or authoritative
branch drops carried evidence, and an in-memory acknowledgement is remembered
per session so repeated snapshots cannot restore a cue the user already
dismissed.

## Lifetime

The cue remains until the next accepted local message, another compaction
starts, or the session changes. Typing, failed submissions, ordinary refreshes,
and elapsed time do not dismiss it. The next accepted submission dismisses only
the composer cue; the transcript's **Context compacted** notice is durable
history and remains. Opening an already-compacted session reconstructs the
historical fact from its saved compaction entries without treating it as a new
alert, and completion never submits or clears a draft or attachment.

## Readiness copy

The completion cue explains whether Pi can accept a message. It mirrors the
composer's real availability instead of adding an input lock:

| Session state | Detail |
| --- | --- |
| Connected and idle, prompt supported | **Ready for your next message.** |
| Connected, still working, steer and follow-up | **Pi is still working. Steer this turn or queue a follow-up.** |
| Connected, still working, steer only | **Pi is still working. You can steer this turn.** |
| Connected, still working, follow-up only | **Pi is still working. You can queue a follow-up.** |
| Connected, still working, prompt fallback | **Pi is still working. You can send a message.** |
| Connected, no supported mode | **Pi is still working. Sending isn't available in this session.** / **Sending isn't available in this session.** |
| Disconnected | **Pi is offline. Reconnect before sending a message.** |

Normal valid-draft, upload, attachment, and disposition checks still decide
whether Send is enabled.

## Synthetic acceptance matrix

The native suites cover the behavior on both clients. Entries marked Mac or iOS
are implemented in the corresponding test target; the render rows are hosted
synthetic renders, not installed-device smoke checks.

| Scenario | Mac test | iOS test |
| --- | --- | --- |
| Persisted entry and explicit event evidence; terminal events return nil | `PiCompactionCompletionTests` | `PiCompactionCompletionTests` |
| Snapshot reconstruction, duplicate snapshots, acknowledgement across refreshes | `PiCompactionCompletionTests` | `PiCompactionCompletionTests` |
| Failed/aborted/settled attempt cannot revive an older cue; branch and session boundaries | `PiCompactionCompletionTests`, `PiConversationReducerTests` | `PiCompactionCompletionTests`, `PiConversationReducerTests` |
| Event survives authoritative recovery; truncated snapshot uses the event cursor; unmatched recovery never publishes | `PiConversationStoreReloadGuardTests` | `PiConversationStoreReloadGuardTests` |
| Terminal outcome clears activity without creating completion; completion survives phase and disconnect | `PiConversationReducerTests` | `PiConversationReducerTests` |
| Progress vs completion precedence, readiness copy, accessibility copy | `PiCompactionPresentationTests` | `PiCompactionPresentationTests` |
| Composer configuration keeps controls and adds readiness | `PiPromptComposerConfigurationTests` | `PiPromptComposerConfigurationTests` |
| Compaction notice stays outside collapsed activity groups | `PiTimelineRowTests` | `PiTimelineRowTests` |
| Accepted submission dismisses only the cue; failed submission retains it | `PiCompactionCompletionTests` | `PiCompactionCompletionTests` |
| Rendered progress, completed-idle, completed-working, and offline states at narrow and wide widths with accessibility text | `PiCompactionRenderTests` | `PiCompactionRenderTests` |
| Compaction blocks submission; drafts survive and are not submitted by completion | — (composer behavior unchanged) | `PromptComposerSubmissionTests`, `PaneDraftStoreTests` |

## Native test commands

Mac:

```bash
xcodebuild -project herdr-harness-mac/herdr-harness-mac.xcodeproj \
  -scheme herdr-harness-mac -destination 'platform=macOS' \
  -derivedDataPath /tmp/herdr-mac-derived \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  test -only-testing:herdr-harness-macTests
```

iOS (discover an available iOS 26 iPhone simulator exactly as the Verify
workflow does):

```bash
DEVICE_ID=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["udid"] for runtime,devices in d["devices"].items() if "iOS-26" in runtime for x in devices if "iPhone" in x["name"]))')
xcodebuild -project herdr-harness-ios/herdr-harness-ios.xcodeproj \
  -scheme herdr-harness-ios -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -derivedDataPath /tmp/herdr-ios-derived \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  test -only-testing:herdr-harness-iosTests
```

Compile-only iOS check:

```bash
xcodebuild -project herdr-harness-ios/herdr-harness-ios.xcodeproj \
  -scheme herdr-harness-ios -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Privacy scan before committing:

```bash
python3 scripts/check-public-source.py
```

## Compatibility and distribution

No new server capability, field, or endpoint is required. Both native clients
use the existing semantic API: a server that emits neither `session_compact`
events nor compaction entries simply shows no completion cue rather than
guessing. The verified Mac release installs only the Mac app; the iPhone/iPad
build and companion server packages are distributed separately through their
own pipelines.

Render artifacts and hosted layout assertions demonstrate synthetic layout at
narrow Mac widths, large Mac text sizes, and iPhone/iPad Dynamic Type sizes.
They are not installed-app verification. An actual device smoke check, if
performed, should be recorded separately from the render evidence.

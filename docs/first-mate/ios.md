# First Mate on iPhone and iPad

First Mate gives each feature its own conversation in the iOS app. Choose a host,
open a feature, and give its First Mate direction in plain English. The companion
server owns the workflow, agents, checkpoints, documents, and saved sessions.
Closing the phone app does not stop work on the host.

## First Mate for iPhone rollout

Phase 0 adds the dark-only Mono × Herdr theme foundation: a cached dusk image,
6% haze band, static glass levels, touch-sized recipes, Dynamic Type fonts, and
First Mate avatar primitives. **Settings → Appearance → Glass / Haze** stores
phone-local preferences, both on by default; Reduce Transparency keeps surfaces
opaque without discarding either preference. Phase 2 installs the chrome on the
new conversations screen, client-built briefing and create/archive sheets. The
**First Mates** tab is dark-only; the legacy System/Light/Dark menu is removed.
Phase 6 puts the cached dusk under the whole TabView while preserving the other
tabs' navigation, content and note-paper colors.

Selected and pressed rows in the new chrome share the quiet 6% `codeFill`
background with 10 pt corners; message bubbles keep 18 pt corners. The whole app
caps Dynamic Type at `.xxxLarge`, including UIKit-hosted Markdown and
metric-scaled controls. This limits scaling, **not message length**: complete
messages remain readable and scrollable, with at least 44 pt control targets.
The cap includes UIKit-hosted Markdown without shortening its transcript.
Passive OS motion/transparency fallbacks remain; they are not independent release
gates or a separate test matrix.

The [implementation plan](ios-chat/IMPLEMENTATION-PLAN.md) and its three research
inventories travel with the source. Those inventories describe the original
baseline, not a promise that later phases are already implemented. No Mac view,
shared First Mate behavior, or server contract changes in Phase 0. Phase 1 now
provides the shared/mobile data layer below. Phase 2 adds the conversations UI;
Phase 3 adds feature chat, composer v1, pushed Info and briefing readouts. Phase 4
adds real lead chat, machine choice, stand-in/recovery, frozen context and lead
Overview. Phase 5 adds attachment, voice, model, mention and feedback controls.
Phase 6 adds the Info restyle, three-column iPad layout and app-wide dusk/capped text.
Each phase retains automated verification/review/landing gates,
without a first-push approval or per-phase device-test pause. One final signed iOS
build is delivered after Phase 6; Phase 7, Mac releases, server deployment and
companion package publication are outside this delivery.

For a Debug simulator build, launch with
`-HerdrDemoMode -HerdrFirstMateDemo -HerdrThemeDuskSample` to inspect the foundation.
`IOSThemeDuskRenderTests` writes `theme-dusk-sample.png` (390 pt), a 402 pt sample,
and an accessibility3-request sample (resolved to `.xxxLarge`) to
`$HERDR_IOS_RENDER_DIR`. `HerdrThemeTypographyRenderTests` compares native
UIKit-hosted Markdown/UIFontMetrics output at the cap, and checks that long
messages lay out completely. The native render harness
supports `background: .dusk`; existing tests still default to `.ink`.
`HerdrThemeAccessibilityTests` measures reading colors and the 0.75 breathing
floor over the brightest cached dusk/haze stack. `HerdrGlassBackgroundTests`
pins canonical bitmap hashes and verifies opacity, one-time darkening, and the
haze fade. `HerdrThemeFoundationUITests` checks the live sample, Settings toggles,
the effective text-size cap, 44 pt targets, and existing tab destinations with
synthetic data.

## Phase 1 data layer

The data layer serves the conversations list and feature chat. The First Mates tab shows a
**global feature-dot badge**: needs-you **and** unread across saved machines,
independent of search/host scope and excluding lead unread. Older companions
without fleet summaries keep attention-style dots; opening them does not invent
read-marker support. One app-active summary loop runs every 10 seconds even on
Agents/Notes; suspension stops it and foregrounding refreshes immediately. The
selected store uses a 3-second visible / 60-second inactive loop. Archive browsing
keeps its exact-host full-list path, separate from the active projection.

Shared Mac rules/tests were mechanically extracted before phone behavior work;
Mac views and local-host preference policy remain unchanged. Phone-owned read,
lead and routing state fences asynchronous results to the saved connection and
feature. New replies survive older read acknowledgements; read failures roll back
with 8–180-second backoff. Lead reads track the observed assistant marker even
when the newest conversation row is a user message; new assistant identities and
post-confirmation unread transitions are not hidden by the old local override.
Lead choice/ensure/context and the new chat route types
are ready for later screens; no prompt is resent or moved on failover.

`herdr://first-mate?feature_id=…[&assignment_id=…][&server_url=…]` and
`herdr://first-mate/lead` are additive phone links. A supplied server origin must
match exactly one configured machine, with no fallback if unknown/ambiguous.
Otherwise an in-chat link uses its captured owner, and an external feature link
needs one unique listed owner across complete, successful host inventories. A
partially discovered, failed or missing inventory is not proof of absence: the
phone explicitly asks for a server-URL link or opening the feature on its machine,
without guessing a first responder or silently queuing a retry. Exact-owner links
remain independent of other hosts' discovery. One navigation intent is established
before app bootstrap; newer links or manual selections fence older results and
errors. Pane URLs/selections, tab selection, car mode and explicit in-app navigation
advance the same intent. Background refresh/recovery does not create a new user
intent or let an older pending pane displace a newer destination. Names, roster ordering and lead metadata never establish identity. Invalid/duplicate/security-bearing fields are rejected; pane
and car links retain their existing behavior. Valid agent links open the current
pushed Agents inspector with the exact assignment expanded and highlighted.

Concrete `FirstMateClient` witnesses now cover lead, context, attachments, voice,
journal snapshots and links. First Mate reads use 15 seconds, normal POSTs 86,400
seconds (matching the shipped long-running mutation contract), with an explicit
90-second upload exception; voice uses 120 seconds. Structured server codes are
retained without changing two-value status catches. This adds transport/data
support, not the Phase 5 attachment/voice/model UI, and needs no server deployment.

Demo mode adds chat-window features/lead on the first synthetic host while
retaining legacy fixture identifiers through the list/detail transition; the second host retains its scenario,
host-only release-checklist feature and its own independent lead history. No demo client starts agents or networks.
Focused coverage includes `FirstMateMobileHTTPContractTests`,
`FirstMateMobileChatStateTests`, `FirstMateMobileDeepLinkTests`,
`FirstMateMobileRouteLifecycleTests`, existing mobile suites and moved shared
rules/outgoing tests. HTTP tests use URLProtocol/fake clients, not a live agent.

## Navigation

The **First Mates** tab opens on **All Machines**. A compact host control sits at
the leading edge; the trailing glass pill contains Search, New feature and More.
The host menu retains All Machines/per-machine scope and remembers an explicit
choice. Search matches presented names, original titles, labels, previews, host
names, goals and tickets. The lead stays visible only for an empty query or one
matching “My First Mate”.

The pinned strip starts with an 88pt lead face, then up to **six** needs-you
features ordered Blocked → Your turn → Ready, with activity-descending ties. A
separate +N orb scrolls to the first hidden feature. Landscape uses 64pt orbs.
Below, flat two-line rows are sorted by activity, with 52pt emoji discs, times,
previews, reason-colored unread dots and status words. Rows use shared
`FirstMateConversation.name`, respecting user presentation metadata without adding
a phone name/emoji editor. Machine-qualified identifiers and accessibility labels
keep same-ID features on different hosts distinct.

The shared `FirstMateReplyProgress` projection reads existing stores outside the
base row cache: pending local/server replies immediately show working/typing,
remove needs-you dots/pins, and affect the **same global phone badge**. Failed
sends and newer activity/replies retire the local bridge; native feature status
and completed rows are preserved. No store or live blur is created per row.

Tap **My First Mate** for a real lead conversation on a capable companion. When
none advertises lead capability, the fallback is explicitly labeled “Built from
your features. Not a message from an agent.” Its Summary uses feature capsules;
tap for a compact 300pt readout and Open chat. The fallback goal composer opens
the existing create sheet with an explicit destination; cancel/failure keeps its
draft. Tap a feature for its chat; the title/Info control pushes its inspector.

## My First Mate (Phase 4)

The global lead destination follows shared machine choice with no local-Mac
preference: valid capable pin, existing conversation, busiest, then roster ties.
Choose **Automatic** or a capable saved host in its face/title menu. The exact
owner and aggregate needs-you/moving/done counts remain visible together. Two
failed LIST polls (capped at three) select a reachable stand-in; one failure,
lead-summary errors and send errors do not. All-down retains the preferred host;
recovery returns to it. The warning names both preferred and answering machines.

An existing lead is fetched without requiring mutation authority; absent leads
are ensured only with that host's control permission. Rendering/polling never
POSTs /lead. A failed snapshot after ensure can retry GET without ensuring again.
Loading, read-only and failure/retry states stay explicit. A capable host failing
to open its lead does not imply every host needs the older briefing fallback.

The same transcript/composer retains machine+feature drafts and histories. A
switch never migrates uploads, reservations or prompts, and never automatically
replays delivery. Shared lead context excludes the owning origin and normalized
reachable peers, includes last-known offline nonarchived features, and retains
the companion's existing bounded-context normalization policy. It is frozen,
including nil, at synchronous reservation; retry keeps the original context,
request ID and payload. No phone call to /lead/remote is introduced. Explicit
captured-owner feature/assignment routes do not become global-choice redirects.

Lead reads use the same mounted visibility/content/layout/source gates and
cancellable retry deadlines as features. A latest USER summary is not a read key:
the matching snapshot supplies the covered assistant; an unloaded newer user or
assistant keeps the lead unread. The lead orb never contributes to feature dots,
even with search/scope changes. Lead Info is Overview only: GOAL, Needs you,
Moving, Done, native status/machine/now and sync state, with exact-owner capsule
readouts and Open chat. Feature-only archive/pause/cancel controls are absent.

Synthetic tests cover nil/read-only/unsupported lead, ensure and snapshot races,
pins/removal/ties, failed-poll thresholds, context provenance and frozen retries.
`FirstMateReadHostTests` mounts both feature and latest-user lead variants.
`FirstMateLeadRenderTests` renders chat/Overview/offline/briefing at320/402 and
capped accessibility3; `HerdrFirstMateLeadUITests` walks actual owner+draft switch,
Info/readout/back, stand-in/recovery and old-host creation. Debug demo flags
`-HerdrFirstMateLeadScenarios` and `-HerdrFirstMateOlderHosts` are synthetic only.
Final two-companion peer acceptance remains part of the single Phase 6 build,
not an intermediate release or live companion permission.

## Composer parity (Phase 5)

Photos and Files upload to the conversation's exact host. The tray offers progress,
retry and remove, with the shared limits of 10 files, 20 MiB per file and 40 MiB
per message. Pending or failed uploads block send. Paste code preserves fences;
uploaded paths become attachment lines. Draft material is kept per machine,
feature and store lifecycle, alongside text. A reservation freezes its complete
payload and detaches it immediately. Explicit retry uses that payload and request
ID; completion never consumes newer edits or moves material to another host.

Hold the mic for 300 ms, then release to transcribe and send. Holding for 2.65 s
locks recording; Stop and send commits it. A quick tap shows guidance, sliding
away or Cancel revokes sending, and VoiceOver activation toggles locked recording
and send. Transcription uses this conversation's companion, with Apple fallback
only after an ordinary provider failure. Cancellation, navigation, backgrounding
or control loss never starts fallback or sends. Recognized text stays with its
original draft; a concurrent edit preserves the result separately for explicit
Append to draft. Voice messages retain the existing dictation caveat.

The expandable accessory area shows coordinator context and Model and thinking.
Settings load from the same host. Running-session changes require confirmation,
a revision-pinned proposal and safe-model capability. Busy/queued turns, pending
outgoing submissions, closed features and lost ownership disable mutations.
Current-session observations remain separate from requested next-turn settings;
Use host default clears both overrides. Context uses the shared unknown/zero/
pressure presentation. Typing @ offers same-machine features and current crew;
chosen names serialize to owned links when sending.

Long-press a canonical First Mate response to Copy, Rate up or Rate down. Saved
ratings appear as reaction badges, including on older and closed conversations.
The feedback sheet supports categories, comments, clear, retry and explicit
conflict reload without discarding the edit. Local optimistic message IDs never
become feedback API targets.

`FirstMateMobileComposerTests` and `FirstMateMobileVoiceTests` exercise ownership,
material reservation/retry, limits, model enablement and cancellation. Native
renders cover 320/402-point composer and sheets at default/capped text. The
`-HerdrFirstMateComposerScenarios` DEBUG fixture provides synthetic attachments,
model confirmation, canned voice and feedback for UI tests without network or
agent dispatch. Physical microphone/Photos and real-companion acceptance use the
single final Mobile App Hub build.

## Feature chat (Phase 3)

Chat hides the tab bar and uses a custom glass back/title/Info/More bar, retaining
native edge-swipe back. A lazy, bottom-anchored transcript follows only within
40pt of the end. Complete messages remain scrollable at the text cap. Bubbles
use 18pt corners, a 5pt terminal tail, shared day/turn grouping and additional
response disclosures. First Mate has no avatar/speaker line; crew messages retain
both. Skims, native Markdown, queued/voice metadata, typing, notices, closed and
read-only states remain available. Long-press copies the original message.

Only server skim reply blocks become inline actions, on the newest eligible
needs-you reply and never while working. Choosing one records a local caption
and reserves a send without consuming a separately composed draft. File cards
come from uniquely associated, visible documents on the exact snapshot; saved PR
cards first honor eligible exact message provenance, including additional responses.
Only links without message provenance may fall back to one unique exact Markdown
URL; earlier quotes, repeated URLs, titles and foreign features cannot relocate a
saved card. File cards open Info →
Documents. Mention runs are cached by content and catalog, bounded, with only
captured-owner names; ambiguous names are not guessed. Feature links open their
chat, agent links validate ownership before opening Agents, and long-press offers
readouts for mentioned features. Retained popovers cannot override newer navigation.

Composer v1 has a 1–7-line scrolling text pill, explicit send, Return for newline,
⌘ Return for send and per-host/per-feature in-memory drafts. Phase 5 extends the
plus menu with Photos, Files and Paste code, and retains View documents. A
synchronous `beginOutgoingMessage` reservation detaches only submitted text,
attachments, mention picks and dictation provenance before transport. Rejected reservations
keep it; newer edits survive completion. Failed/uncertain delivery offers explicit
Retry/Copy; retry keeps the original owner, lifecycle, payload, request ID and
frozen context, including nil. Polls never resend or migrate the submission.

Phone-owned read hooks require an appeared, active, topmost First Mates chat at
the end with a server read key represented by the current transcript and its fresh
layout observation. A newer fleet summary alone cannot acknowledge an unfetched
reply, and collapsed additional responses confer no read authority. Pushed Info,
offscreen render hosts, sheets, root covers, other tabs and background scenes do
not acknowledge reads. Inline iPad Info leaves the visible chat eligible; opening
its document or saved-session sheet covers chat and cancels its pending marker. Optimistic clearing does not cancel its own transport. Failure deadlines
schedule visibility/source-fenced retries at 8–180 seconds even when healthy polls
publish no changes; shared last-seen semantics are unchanged. Mounted native-host
tests use cancellation-aware held clients and a virtual retry clock. Chat and pushed Info
use exact-store control leases; stale disappearance cannot revoke a newer grant.
Inline Info shares chat's lease, so hiding it cannot revoke a chat control grant.
The old detail/chat/message/composer and inspector-sheet host are removed.

Creating from All Machines requires an explicit destination before accepting a
repository folder; single-machine scope preselects that host. Recent folders
belong to the destination, changing it clears the folder, and submitted values,
request ID and owner context are frozen before asynchronous work. A creation
receipt is cached without selecting it; only the still-current navigation intent
can select the new feature, so an older create cannot steal a newer same-host chat.
The capped
form has Next field/Done keyboard controls. Ordinary Pi chats remain in Agents.

Swipe or long-press a row to archive it. The restyled confirmation captures the
exact store/lifecycle and optional reason, retains all records and explains when
work continues. Active removal is optimistic and rolls back on failure; stale
confirmations cannot target a replacement connection. Archive freshness uses
`updated_at`, not workflow revision: newer active inventory can reveal a remotely
unarchived feature without fetching its full snapshot. Unarchive feedback clears
on retry/success with owner/lifecycle/operation fencing; unrelated polling retains
a genuine failure. **More → Show archived**
uses a separate host-store inventory, not the active-only projection; swipe or
long-press an archived row to unarchive it. Known presentation names/emoji survive
local archiving; cold archived inventories use the metadata their host provides.
Hosts without `first-mate-archive-v1` keep their active list and update guidance.

On iPhone, a feature opens its conversation. Use the feature controls to inspect
Overview, Agents, Documents or Workflow, then return to the same conversation.
Underline tabs scroll horizontally at narrow widths. A persistent footer shows
sync state and revision. Mention navigation highlights only the exact assignment
inside that owner, including its saved-session action. A different feature starts
on Overview; rotation keeps the current feature, inspector, route and draft.
On iPad, a NavigationSplitView keeps the conversation list, chat and Info in three
columns. The lead has only Overview, and older-host briefing remains explicit.
The whole app uses dark dusk chrome and capped scalable text with native scrolling.
Widget colors are unchanged.

The conversation holds only your messages and First Mate's replies, stage
results, and requests for your direction, as on Mac. Background activity,
including First Mate's private notes, appears under Overview's **Latest in the
journal** and in Workflow's activity log. This needs a companion advertising
`first-mate-quiet-chat-v1`; see [what reaches the chat](conversation.md).

Workflow offers a journal and a graphical route through recorded stages. Each
stage exposes its documents and agents through compact controls. Open an agent
to read its exact saved Pi session, including retained sessions from handoffs.
Earlier transcript pages can be loaded without switching to a newer conversation.
Documents retain their producing agent and session. The seven-reviewer demo shows
how a larger team remains accessible without filling every workflow card.

## Behavior and compatibility

Mac and iOS compile the same First Mate models, observable store, resource loader,
and synthetic demo from `HerdrFirstMateShared`. Their native layouts are separate.
Both use the authenticated `first-mate-v1` companion API. The matching server
release is required; an older server shows an update explanation. Updating the
phone app does not install or activate a companion server.

The app polls every configured host while the app is active, including on other
tabs, and refreshes the selected conversation on its own cadence. Hosts fail independently: one
offline, stale, or older companion shows its own notice and keeps its cached
features readable without clearing a healthy peer. Switching features preserves
their unsent drafts in memory. Returning from another tab or from the background
preserves the current feature and the current machine scope. Opening a feature
never changes that scope.

The scope preference is versioned under `herdr.firstMate.scope.v1`. A missing,
invalid, or upgrade-only legacy value opens on All Machines, and the older
`herdr.firstMate.machine` key is never read or rewritten. A saved host that
leaves the roster resolves to All Machines rather than another machine. Detail
navigation, delayed confirmations, creation, messages, workflow resources, and
archive actions always resolve the exact machine that owns the feature, never a
host that merely shares its feature ID. Changing connection credentials retires
every host store, closes an open create sheet, and clears invalid navigation
before a delayed response can repopulate it. Drafts are not persisted across app
launches.

Every major workflow stage still waits for human direction. Sending a message
records a request and returns control to the conversation while the host proceeds
asynchronously. Pause, resume, and cancel act on that feature. Cancel requires
confirmation. Viewing a document or saved session does not send an agent a prompt.

## Local verification

Phase 6 adds `FirstMateInfoRenderTests` for all four Info tabs and resource sheets
at 320/402 points, default/capped text, plus actual three-column 1024/1366-point
renders on an iPad simulator. `FirstMateReadHostTests` mounts chat beside Info and
checks held reads through tab changes, inspector disappearance and resource-sheet
coverage. `HerdrFirstMatePolishUITests` walks Info/resources and all app tabs at the
text cap on iPhone, and preserves selection, Info and an unsent draft through iPad
rotation. `HerdrThemeAccessibilityTests` covers the brightest dusk/card stacks and
all six note-paper/ink pairs at 4.5:1. These are synthetic simulator checks; physical
microphone, Photos and two-companion peer acceptance use the final Hub build.


Phase 3 uses `FirstMateMobileTranscriptTests` plus existing shared conversation,
mention/outgoing and mobile read/navigation/lifecycle suites. `FirstMateChatRenderTests`
checks Receipt export, the briefing, idle/focused/closed composer and readout at
320/402pt, including accessibility3 requests capped at xxxLarge and full long text.
`IOSSkimRenderTests` now exercises the replacement bubble. `HerdrFirstMateChatUITests`
walks send, pushed Info/Documents, file cards, edge-swipe back, briefing readout and
creation-draft cancellation. DEBUG-only `-HerdrFirstMateTranscriptPerformance` with
demo mode seeds 200 messages and a complete 24-paragraph final reply. Non-observing
body/visibility counters and measured XCTest gesture/settling time are evidence,
not an assertion of full-frame-rate rendering or a substitute for final-device checks.

Launch with `-HerdrFirstMateDemo` for synthetic features without a server. The
demo configures two synthetic hosts, `desktop` and `laptop`, that share feature
IDs and add one laptop-owned feature, so All Machines aggregation, owner labels,
and single-machine filtering are visible without live agents. The scenario
control advances the shared planning, implementation, seven independent reviews,
human checkpoint, revised direction, and verified session handoff states.
Ordinary `-HerdrDemoMode` continues to open the existing Agents experience.

Use the repository's iOS Xcode scheme and verification instructions. Shared
First Mate contract tests compile into both the iOS and Mac unit-test targets.
`FirstMateConversationsRenderTests` exercises native list/row renders at
320/375/402/430pt and accessibility3 requests capped to `.xxxLarge`, asserting
control/label geometry and 44pt targets. `HerdrFirstMateConversationsUITests`
walks host scope, lead briefing, retained chat, search, capped creation/archive
and unarchive. Debug-only `-HerdrFirstMateListPerformance` (with demo mode) supplies
100 synthetic rows and a More → List diagnostics counter; tests measure actual
lazy row-body/visibility counts and scrolling time, not an invented FPS claim.
The existing iOS UI suites retain feature navigation, composing direction,
workflow resources, larger text and machine-scope coverage. `HerdrFirstMateMachinesUITests`
verifies the All Machines default, both demo hosts in the combined list, All →
one machine → another machine → All, an unchanged scope after detail navigation
and tab return, an explicit creation destination, and reachable controls at
accessibility text sizes. Test screenshots use synthetic data only.

### Authenticated simulator fixture

From the repository root, start the local fixture:

```sh
python3.11 scripts/first-mate-ios-fixture.py --port 9196
```

It binds to loopback and uses the production HTTP handler, authentication,
First Mate SQLite store, and saved-session reader. Its runtime cannot launch
agents. Create and message requests receive a deterministic acknowledgment and
do not advance workflow stages. Routes outside First Mate and the basic host
status reads are unavailable.

Each run creates a fresh directory under ignored `build/first-mate-ios`. The
`fixture-current.json` manifest gives the URL, synthetic token, feature and
workflow IDs, sample project folder, and request log path. `requests.jsonl`
records request methods, paths, bodies, and timestamps, without authentication
headers. Stop the server with Control-C. Restarting creates a new isolated fixture.

The seeded feature contains three completed workflow steps, three Planning
documents, seven independent reviewers, and thirteen saved sessions. The
architect session has 235 messages for pagination checks. Both the implementation
handoff and a predecessor First Mate conversation remain accessible.

Launch the iOS Debug build with these arguments, using the manifest's `cwd` value
when creating a new feature:

```text
-HerdrUITestServerURL http://localhost:9196
-HerdrUITestAPIToken synthetic-first-mate-ios-token
-HerdrOpenFirstMate
-herdr.smartAlerts NO
```

The fixture credentials live only in launch arguments. They are retained when
the client reconnects and are not saved to Keychain. To prepare the dataset and
verify its saved-session reader without starting HTTP, use `--seed-only`.

Run the four First Mate UI suites on an available simulator:

```sh
xcrun simctl list devices available
xcodebuild -project herdr-harness-ios/herdr-harness-ios.xcodeproj \
  -scheme herdr-harness-ios \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -only-testing:herdr-harness-iosUITests/HerdrFirstMateMachinesUITests \
  -only-testing:herdr-harness-iosUITests/HerdrFirstMateUITests \
  -only-testing:herdr-harness-iosUITests/HerdrFirstMateServerUITests \
  -only-testing:herdr-harness-iosUITests/HerdrFirstMateNavigationUITests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

Replace `SIMULATOR_UDID` with a device from the first command. The authenticated
UI case checks for the fixture before running and skips when it is absent; the
synthetic demo cases do not need a server. Simulator ad hoc signing is enabled
because the host-navigation case exercises a real Keychain save. An unsigned
simulator build can fail that save before navigation is reached. Run the suite
on both an iPhone and an iPad simulator; iPadOS exposes its tab bar differently,
and the tests account for both shapes.

### Post-install two-machine smoke checklist

After installing a signed iOS build on a phone or iPad with two configured
machines:

1. Open **First Mate**. It starts on **All Machines**, features from both hosts
   appear together, and every combined card names its host.
2. Choose machine A and confirm only A's features remain; choose machine B and
   confirm only B's features remain.
3. Choose **All Machines** again and confirm the combined list returns.
4. Open a feature on A, send a short direction, and confirm the reply is retained
   on A's feature only.
5. Open a feature on B and confirm its composer, documents, and saved sessions
   load from B, including an exact-session open.
6. Stop or disconnect machine B. Confirm B shows its own unavailable or stale
   notice with any cached features readable, while A's features stay usable.
7. Create a feature from All Machines. Confirm a destination must be chosen,
   choose B, and confirm the new feature appears only under B.
8. Archive a feature on A, then reveal it with **Show archived** and unarchive
   it; confirm the owning host reflected both changes.
9. Return from another tab and reopen First Mate, then open and close a feature;
   confirm the chosen scope and the selected feature are unchanged.

The signed Mac update feed installs only the Mac app. It does not install or
update this iOS build, and publishing a Mac release does not deliver this
feature to an iPhone or iPad; ship it through the separate iOS pipeline.

# First Mate HUD: build spec

The First Mate HUD is a small floating widget on the Mac. One lead First Mate sits in a circle, and every active First Mate feature ("second mate") hangs under it. You glance at it to see who needs you, you talk or type to First Mate, and you open a feature's session from it. Long reading and attachments stay in the main app.

**Design reference:** `reference.html` in this folder. Open it in a browser. It is a playable HTML prototype with made-up data. Match its look, sizes, motion and interactions. Where this spec and the prototype disagree, this spec wins. The side panel's **Spec** section repeats the key measurements.

Other files in this folder are earlier explorations (`list.html`, `list-v1..v3.html`, `index.html`, `jarvis*.html`, `v1.html`). Ignore them unless you want history.

---

## 1. What to build, in phases

| Phase | Scope | Ships when |
|---|---|---|
| **1. HUD on real data** | Panel, face orb, collapsed row, expanded list, overflow, hover readouts, open session, read/unread, type and talk to one feature, fleet summary and read-state API | A user can run it all day against real First Mate features |
| **2. Lead First Mate** | A cross-feature lead that answers "what needs me?", checks with features, and relays decisions as the user's messages | Phase 1 is in use |
| **3. Motion extras** | Signals traveling along the line, the scan beam, drag a row onto First Mate to ask about it | Nice to have |

Build Phase 1 first. Leave clean seams for 2 and 3, but don't stub fake behavior into production code.

---

## 2. Where it lives in the code today

Build from the latest `origin/main`. The Mono × Herdr theme (`HerdrTheme` with `Radius`, `Glass.hud = 0.78`, and the status colors) is there. Some local checkouts are behind.

**macOS HUD** (`herdr-harness-mac/herdr-harness-mac/`)
- `State/HerdrHudController.swift`: `HerdrHudPanel: NSPanel` is borderless, non-activating, at level `.statusBar`, and joins all spaces. Reuse this pattern for the First Mate HUD panel, including placement (`State/HerdrHudPlacement.swift`), drag (`Views/Hud/HerdrHudWindowDragHandle.swift`) and Esc handling.
- `Views/Hud/HerdrHudOrbView.swift` is the existing 56 pt agent HUD orb. It is not the First Mate orb.
- **Voice:** `Views/Pane/HerdrQuickVoiceCapture` supports `beginHold` (press and hold) and records with `HerdrVoiceRecorder`. Transcription runs through `HerdrAppModel.transcribeVoiceNote`, then `VoiceTranscriptionPipeline` (`Models/VoiceTranscription.swift`): server first, with on-device `SpeechAnalyzer`/`SpeechTranscriber` as the fallback.
- **Open a session:** `herdr://first-mate?feature_id=…&server_url=…` is parsed by `FirstMate/FirstMateOpenRequest.swift` and handled in `Views/Root/AppRootView.swift`.
- **Status labels today:** `FirstMate/FirstMateStatusLabel.swift` uses hard-coded colors. Use `HerdrTheme` tokens instead.
- **Demo mode:** launch with `-HerdrDemoMode`. `HerdrFirstMateShared/FirstMateDemo.swift` has demo data. Put the synthetic HUD fleet there.

**Shared model** (`HerdrFirstMateShared/`)
- `FirstMateFeature.status` is a string: `ready, coordinating, running, awaiting_direction, paused, blocked, completed, cancelled, recovering`. The client can also derive `unverified`.
- The current stage is `snapshot.currentVisit.stageKey`. First Mate stage keys are chosen per feature and are not a fixed list.
- **Missing today:** no emoji, short label, percent, or read/unread anywhere. `FirstMateMessage.status` is queue state (`queued/processing/done`), not read state.
- `FirstMateStore.refresh()` fetches the feature list, plus detail for the selected feature only.

**Server** (`herdr_harness/`)
- Routes live in `server.py` `_first_mate_route`, under `/api/v1/first-mate`.
- Storage is `first_mate_store.py` (SQLite `fm_*` tables). The coordinator runtime is `first_mate_runtime.py`.
- The canonical 8-stage pipeline is `DEFAULT_PIPELINE_STAGES` in `active_work.py`. A feature links to Active Work only through the optional `work_item_id`.
- There is no cross-feature lead First Mate. "Lead" inside a feature means a lead assignment with child reviewers.

**Contract rules** (`docs/first-mate/build-contract.md`, `AGENTS.md`)
- snake_case JSON.
- New behavior sits behind a capability flag.
- Older clients ignore new optional fields.
- No HTTP action may bypass a human gate.
- The server, Mac, iOS and web must stay compatible.

---

## 3. New server contract (Phase 1)

Add capability `first-mate-fleet-v1`. Clients show the HUD only when the server advertises it. The First Mate chat window (`../first-mate-chat-2026-09-27/BUILD-SPEC.md`) uses the same data under the same capability; whichever lands first builds it, and the other reuses it.

### `GET /api/v1/first-mate/fleet`
A small summary for every feature that isn't `completed` or `cancelled`, plus anything completed in the last 2 minutes, so the HUD can show "merged" before the feature leaves. Poll it every 5 s while the HUD is visible and every 30 s while it's hidden. Never fetch full snapshots for the HUD.

```json
{
  "features": [
    {
      "feature_id": "fm_123",
      "title": "Receipt export",
      "label": "Receipt export",
      "emoji": "🧾",
      "status": "blocked",
      "hud_status": "blocked",
      "step_index": 3,
      "step_fraction": 0.45,
      "percent": 58,
      "now": "QA failed twice. The export sheet never appears on iPad.",
      "latest_message": { "id": "msg_9", "text": "…", "created_at": "…" },
      "unread": true,
      "updated_at": "…"
    }
  ],
  "generated_at": "…"
}
```

- **`label`**: a short name, 24 characters at most. Default to `title`, trimmed.
- **`emoji`**: user-chosen, with a server-side default, for example picked from a small set by hashing the feature id.
- **`now`**: one line, 120 characters at most. Use the latest progress summary (`assignment.metadata.progress.summary`) or the latest First Mate message.
- **`step_index`** (0 to 5), **`step_fraction`** and **`percent`**: see section 4. Send `null` when unknown; the HUD then shows an empty ring and hides the percent.

### `POST /api/v1/first-mate/features/{id}/read`
Body: `{ "through_message_id": "msg_9" }`. Stores a per-feature read marker on the server, so the Mac, iPhone and web agree.

A feature is **unread** when its newest First Mate-authored message is newer than the marker. Mark it read when the user opens its message card, opens its session from the HUD, or has the lead relay the message (Phase 2).

### `POST /api/v1/first-mate/features/{id}/hud`
Body: `{ "label": "...", "emoji": "..." }`. Lets the user rename a feature or change its emoji. Store both server-side.

Tests: route and store unit tests in `tests/`, covering the status mapping, step mapping, read markers and label limits. Extend `FirstMateClient`/`HerdrAPIClient` with matching Swift types and decode tests. Older clients must keep working.

---

## 4. Mapping real state to the HUD

### Status (`hud_status`)
| HUD status | Color token | Comes from |
|---|---|---|
| `blocked` | `HerdrTheme.alert` (#E2A7B6) | `blocked`; also `recovering` when `recoveryNeedsDirection` is true |
| `turn` ("Your turn") | `HerdrTheme.attentionBadge` (#FF9F0A) | `awaiting_direction`, when the question isn't about approving finished work |
| `ready` ("Ready for review") | `HerdrTheme.signal` (#9CCDB9) | `awaiting_direction` at a review or PR stage (a PR or result is waiting for approval) |
| `working` | `HerdrTheme.working` (#E4C386) | `coordinating`, `running`, `recovering`, `unverified` |
| `idle` | `HerdrTheme.tertiaryText` | `ready` (not started) and `paused`. They show in the moving group with a grey ring |
| `done` | `HerdrTheme.signal` | `completed`. Shown as "Merged" for 2 minutes, then it leaves |

Needs-you means `blocked`, `turn` and `ready`. Put the rule for splitting `turn` from `ready` in one server function, and make it easy to change (see open decisions).

### Steps (Plan, Build, Review, QA, PR, Merge)
If the feature has a `work_item_id`, map its Active Work stages:

The badge follows the current visit's active assignment roles: planner means
Planning, coder/implementer means Building, reviewer means In review, and an
explicit qa role means In QA. Mixed or custom roles have no single phase and
show Working. A new human message or active coordinator clears the phase while
direction is being interpreted. Without active assignments, only an exact
canonical stage name identifies a phase. Free-form keys such as
`test-fixture-cleanup`, `phase-3`, and `code-review-pre-pr` remain unknown.

A phase does not establish a six-stage pipeline or completion percentage.
`step_fraction` and `percent` are null until there is evidence for progress;
the native header names the phase without saying "Step N of 6". Completed means
Complete, not Merged. A saved PR URL never establishes draft or review readiness.

---

## 5. Visual spec

All sizes are in points. Dark-first. Use `HerdrTheme` tokens and don't add new colors, except the face's eye color (#D9D6FF), which is a lighter lavender.

### First Mate orb
- **Size:** an 86 pt circle. The glass disc inside is 66 pt, with an accent-tinted radial glow.
- **Rings:** an outer accent ring at 0.8 opacity, and 60 ticks.
- **Face:** two rounded-rect eyes (8 × 12, 4 pt radius, 17 pt apart) and a small smile. Draw them as vector shapes with an accent glow.
  - **Idle:** it blinks about every 5 s and the eyes follow the pointer by up to 2.4 pt.
  - **Thinking:** the eyes glance side to side and two dashed arcs rotate outside the ring.
  - **Listening:** the eyes turn rose and widen 16%, the mouth becomes a 5-bar level meter, and 48 spectrum ticks pulse outside the ring.
  - **Speaking** (a reply just landed, about 1.3 s): the mouth is a pulsing oval.
- **Count badge** at the top right: the number of needs-you features, colored by the most urgent status (blocked, then your turn, then ready). Hidden at zero.

### Collapsed view (the default)
- **Layout:** one row of halo orbs centered under First Mate, their centers 66 pt below its center and 34 pt apart. **No background.**
- **Halo orb:** 30 pt. A dark glass core with the emoji, surrounded by the six-step progress ring in its status color, with a soft glow. There's no badge.
- **Message waiting:** a dashed accent ring turns slowly around the orb (7 s per turn). Nothing spins otherwise.
- **Overflow:** at most **6 orbs, including "+N"**. See section 6.
- **Chevron:** a 22 pt button under the row, which opens the list.

### Expanded view
- **The line:** a lit accent line runs down from First Mate. The rows hang from it: each has a 38 pt status node on the line and a **236 pt** glass slat to its right, at 38 pt tall and 46 pt pitch.
- **Slat, line 1:** the label and the state word. The state word is the status for needs-you rows and the current step for moving rows.
- **Slat, line 2:** a six-segment bar and the percent.
- **Needs-you rows** get a tinted border in their status color.
- **Unread:** an accent speech bubble with three dots sits to the right of the slat.
- **Groups:** needs-you rows sit on top, ordered blocked, your turn, then ready, with ties in start order. Then a small diamond on the line. Then moving rows in start order. A row only moves when its status changes. If it jumps several places, it shrinks to its node, swings out, and reopens in its new slot.
- **Compact rows:** 24 pt tall at 30 pt pitch, with a smaller node. They show one line (label, step and percent) and a 2 pt bar.
- A chevron on the line under First Mate collapses the list.
- **Size:** about 330 × 410 pt with 6 features. The panel must never cover the full screen.

### Panels
- Glass is `HerdrTheme.Glass.hud` (78%) over `base`, with blur. Radii come from `HerdrTheme.Radius` (cards 12, chat 16).
- **Hover readout:** a 300 pt card. It shows the full title, status, the "now" line, six labeled step bars, progress, time in the current step, agents, pull request, and the buttons Open session and Read message (or Ask First Mate). It has accent corner brackets, and a leader line joins it to its row or orb.
- **First Mate's latest line:** a small preview bubble beside the orb, 3 lines at most. It stays until read, or for 5.5 s for soft notes.
- **Chat panel:** 352 × 420, beside the HUD on whichever side has room.

### Motion
- **Springs:** stiffness 130 and damping 16, for rows moving to their slots.
- **Folding:** rows fold into orbs and unfold top-first, 35 to 50 ms apart.
- **Reduce Motion:** turn off blinking, glancing, spinning and springs (snap into place instead). Keep the state colors.
- Nothing animates while idle except the blink and the unread ring.

---

## 6. Overflow rules

The principle: **what needs you is never hidden. Features that are only moving are compressed.**

- **Collapsed:** if there are more than 6 features, show the first 5 in list order, and the 6th slot becomes **"+N"**. Its ring has one arc per tucked feature, in that feature's status color, and it gets the dashed unread ring if any tucked feature is unread.
  - **Hover "+N":** a card lists the tucked features (emoji, label, step, percent, bar). Clicking one opens its session.
  - **Click "+N":** opens the list with all moving rows showing.
- **Expanded:** show every needs-you row in full. If there are more than 4 moving rows, show 3, then a **summary row**: "N more moving", their emoji, and their average percent.
  - **Click the summary row:** all moving rows show as compact rows, and the summary becomes "Show fewer".
  - **Hover the summary row:** shows the same list card as "+N".
- If a tucked feature is opened from chat, it comes out first.
- **Fit:** 14 features, with everything showing, still fit on a 680 pt-tall screen area. If the screen is shorter, cap the needs-you rows and scroll only the moving section.

Put the overflow decisions in one pure function: features in, and out come slots, a tucked list, a compact flag and "+N" contents. Unit-test it.

---

## 7. Interactions

| Gesture | Result |
|---|---|
| Click First Mate | Opens the chat to type |
| Press and hold First Mate (0.42 s) | A rose ring fills, then listening starts. A live caption shows words beside the orb. Release to send; Esc cancels. It sends automatically, with no review step |
| Drag First Mate | Moves the whole HUD. It keeps itself on screen, and near an edge the list shifts to fit |
| Hover a row or orb | Readout card after 220 ms |
| Click a row | Opens that feature's session in the main app |
| Click an orb | Opens its message if it has the dashed unread ring; otherwise opens its session |
| Click the speech bubble | Message card in place: the text, one-tap reply buttons, a reply box with a mic, and Open session. Opening it marks the message read |
| Right-click a row or First Mate | Change the emoji and label (24 characters max) |
| Chevron | Collapse or expand |
| Esc | Steps back: editor, then listening, then card, then chat |

**Voice:** use `HerdrQuickVoiceCapture.beginHold` with the existing transcription pipeline. Show live partial words if the on-device transcriber provides them. Otherwise show the waveform and "Listening…", then the final text for about 0.5 s before it sends.

**Phase 1 routing** (no lead yet):
- Typed or spoken text that names a feature (by label or alias), a drag onto the orb (Phase 3), and reply buttons all post to `POST /features/{id}/messages` as the user's message.
- A general question ("what needs me?") is answered locally from the fleet summary with a template sentence. For example: "Two need you: Receipt export is blocked in QA, and Push alert settings has a question."
- Say so plainly when nothing matches.

**Phase 2, lead First Mate:** a server-side agent that reads the fleet summary, checks with features, and answers. Decisions go to the feature as the user's message and never bypass a human gate; the lead has no stage authority of its own. It marks a message read when it relays it.

---

## 8. Accessibility and quality
- Every orb and row is a button with a label like "Receipt export: blocked in QA, 58 percent. Unread message. Opens the session."
- Full keyboard path: Tab through the rows. Enter opens, E edits, Esc steps back.
- Text contrast is at least 4.5:1 on the glass, which the Mono theme already guarantees.
- **Performance:** draw the line, rings and glow in one `Canvas`. Use `TimelineView` only while something animates. Idle CPU should be near zero.

## 9. Testing and delivery
- **Tests:** unit tests for the status and step mapping (server), read markers, the overflow function, and client decoding. Add a demo-mode fleet of 6, 10 and 14 synthetic features, with multi-word names, for visual checks.
- **Focused checks while building:** `.venv/bin/python -m unittest discover -s tests` (or a targeted module), and `xcodebuild -project herdr-harness-mac/herdr-harness-mac.xcodeproj -scheme herdr-harness-mac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`. Run the full matrix only on the final candidate.
- **Before every commit:** `.venv/bin/python scripts/check-public-source.py`. Use synthetic data only in source, tests and screenshots.
- **Commits:** no AI attribution or Co-Authored-By lines.
- **iOS and web:** they must keep working with the new optional fields, and don't need the HUD.

## 10. Open decisions (ask before assuming)
1. **Placement:** does the First Mate HUD replace the agent HUD orb or sit beside it? Default: a separate panel behind a setting, with the agent HUD unchanged.
2. **Your turn vs ready:** an earlier Mono branch colored `awaiting_direction` green ("Your direction"), but this design uses orange for "your turn" and green only for "ready for review". Confirm the split rule in section 4, and update `FirstMateStatusLabel.swift` to match.
3. **Hotkey:** a global push-to-talk key? `Ctrl+Option+Space` already toggles the agent HUD.
4. **Default emoji:** hashed from a set, or picked by the coordinator from the title?

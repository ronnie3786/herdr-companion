# Smart input in the Mac report sheet

The Mac app's **Report a Bug or Request a Feature…** sheet (Help menu, ⌘⌥F, or
Settings → General → Feedback) keeps its ordinary manual workflow. An optional
**Smart input** section above the Title and Description fields adds two explicit
preparation actions:

- **Draft with AI** — one short, tool-free AI run that rewrites a plain-English
  request into a title and a structured description.
- An inline microphone — click once to record, click again (or reach the
  ten-minute cap) to stop. The finished recording is transcribed by the
  selected companion's configured transcription service and appended to the
  same smart-input box.

Neither action files anything. The smart-input text and any recording go only
to the selected companion's configured services; only an explicit **File report**
publishes the reviewed title and description — and any attachments — as a public
GitHub issue.

## Interaction

- The sheet opens with the smart-input box focused. Both report kinds (Bug and
  Feature request) use the same box.
- **Draft with AI** needs only the plain-English text. It disables itself while
  busy, so a second click cannot start a duplicate run.
- A successful draft replaces both Title and Description atomically. Both
  generated fields remain editable, and the untouched source text stays in the
  box for another draft.
- One **Restore previous** action puts back the title and description the last
  generated draft replaced. It is offered only while nothing has edited those
  fields since, the report kind and target have not changed, and no submission
  is underway. It disappears after one use, and it never overwrites a newer
  manual edit.
- A manual edit made while a draft is in flight wins: the late result is
  refused as a whole (neither field changes) and the sheet says why.
- While drafting, recording, or transcribing, **File report** is unavailable;
  filing a report cannot race the preparation of its own fields.
- Failures keep the typed source and the report unchanged. A failed
  transcription keeps the recording privately inside the sheet for one explicit
  **Retry transcription** or **Discard recording**; the audio is deleted on
  success, replacement, cancellation, or dismissal.

## Drafting profile

Drafting uses the companion server's dedicated, additive
`issue-report-draft-v1` Agent-run profile:

- The app reads the selected companion's
  `/api/v1/agent-runs/capabilities` and requires `issue-report-draft-v1` in
  `profiles` (also described in the additive `issueReportDrafts` object). The
  profile name, limits, and JSON response shape mirror the server module
  `herdr_harness/issue_report_drafts.py`.
- The request body carries exactly `profile`, `kind`, and `text`. The server
  rejects every other field rather than ignoring it, so a draft cannot smuggle
  an attachment, working directory, model override, system prompt, pane scope,
  continuation, or supplied context.
- The server starts exactly one run in `ask` mode with **thinking Off**, no
  tools, no extensions, no profile snapshot or awareness bootstrap, and an
  empty topology. If a configured server execution timeout is shorter, that
  shorter timeout applies; the profile never exceeds 60 seconds. The client
  polls to the same 60-second deadline and best-effort cancels the remote run
  when the deadline or the sheet ends. Nothing retries automatically.
- The source text travels to Pi on stdin as the JSON object
  `{"kind": …, "text": …}`. It is not interpolated into a system prompt.
- **Pi default model.** The profile does not choose a model. An omitted model
  delegates to the execution companion's Pi default, exactly as
  `herdr-harness-mac/herdr-harness-mac/Models/AgentModelSettings.swift` documents
  for other calls. There is no model picker in the report sheet, no provider is
  hardcoded, and no other machine or model is silently substituted. The provider
  must work in that companion's environment.
- The server validates the response as exactly one JSON object with exactly the
  string fields `title` and `body`. A blank, oversized, control-bearing,
  missing, or extra field is refused before anything touches the report, and
  raw model output is never echoed into the sheet.

### Writing policy

The server-owned charter asks for a concise single-line title and a Markdown
body structured for the chosen kind: for a bug, the observed problem and
impact with concise numbered reproduction steps plus expected versus actual
behavior; for a feature, the requested outcome, motivation or use case, and
acceptance criteria. It must preserve every concrete detail the user supplied
and must not invent facts, versions, error messages, reproduction steps,
requirements, or promises. It does not ask follow-up questions.

### Limits

| Value | Limit |
| --- | --- |
| Smart-input source | 20,000 Unicode scalars |
| Drafted title | 200 Unicode scalars |
| Drafted description | 20,000 Unicode scalars |
| Drafting execution | at most 60 seconds (or the shorter configured server timeout) |
| Recording | 0.5-second minimum, 10-minute maximum (the existing recorder policy) |

An over-limit or control-bearing source keeps every character in the box and
shows a validation message instead of silently truncating it. The same applies
to a transcript that would take the box over the limit.

## Recording and transcription

- The smart-input section has one inline microphone control. It glows only
  while the recorder actually captures; a pending macOS permission prompt shows
  a cancel symbol and an explicit status instead, because a requested recording
  is not yet evidence of capture. There is no recorder sheet, waveform, timer
  panel, or playback UI, and the control is still the same inline element while
  recording.
- The first click requests the system microphone permission when macOS has not
  decided yet; required permission prompts remain visible and are never
  bypassed. Denial is actionable and retains nothing.
- Stopping sends the finished WAV exactly once to the selected companion's
  already-configured transcription endpoint through the same quick-voice route
  (`transcribeVoice`). There is no hidden fallback to Apple Speech or another
  host: if the selected companion cannot transcribe, the sheet reports an
  actionable error and keeps typed text.
- The transcript is appended to the smart-input box with a paragraph separator,
  preserving anything typed meanwhile. It never writes into the Title or
  Description fields and never starts a draft or a submission by itself.
- The ten-minute cap ends the capture through the same finished-capture
  callback as an explicit Stop, so the automatic completion transcribes once
  rather than racing a second send.
- Transcription requires `[providers.transcription]` to be configured on the
  selected companion; see the transcription row of the README's optional
  integrations table.

### Accessibility and Reduce Motion

- Accessibility never depends on the glow: the status line (`Recording…`,
  `Transcribing…`, `Waiting for microphone permission…`) is explicit, and the
  mic's accessible label names the action it will take (`Record a description`,
  `Stop recording`, `Cancel recording`).
- The glow is a steady ring and fill while capture runs. Reduce Motion
  removes its fade transition; no repeating animation is used.

## Privacy

- The smart-input text is sent only in one explicit `issue-report-draft-v1`
  request to the selected companion's configured Pi. Environment details,
  attachments, topology, and conversation history are never part of a drafting
  request.
- A recording is sent only on Stop, only to the selected companion's configured
  transcription service. It is never attached to the issue.
- Generated or transcribed text reaches GitHub only after the user reviews and
  edits the fields and chooses **File report**; the description is then filed
  exactly as written, together with the environment table and attachments.
- The smart-input section shows which companion prepares the draft and states
  this boundary in the sheet.

## Companion compatibility

`issue-report-draft-v1` is additive to the existing `issue-reports-v1` report
API. The drafting action itself requires a companion server that advertises it:

- If the companion does not advertise the profile, the app never sends a
  drafting request (an unknown profile would otherwise be rejected), disables
  only **Draft with AI**, and shows actionable upgrade guidance. Manual
  reporting, attachments, the environment disclosure, autofix selection, and
  transcription keep working.
- If the companion is unreachable, drafting reports that and keeps the typed
  text; **Check again** re-probes the same selected companion.
- An older companion keeps the report API usable. Drafting does not fall back
  to a generic agent profile, and no other machine is contacted.

The Mac updater installs only the Mac app. Install the companion package
separately on each machine that should draft or transcribe for this sheet, and
keep the installed CLIs, Pi extension, and workers in step with the server
revision. See [herdr_harness/README.md](../herdr_harness/README.md) for the
server update procedure and [macOS releases](macos-releases.md) for the app
feed. A server cutover is never implied by a Mac app release.

## Verification

### Deterministic automated evidence

The fixture-backed suites use injected transports, draft services, recorders,
and transcribers with synthetic data. They do not contact a provider or the
microphone, and they publish nothing:

- `IssueReportDraftTests` — the client contract: exact request body, strict
  output parsing, error descriptions, and source validation.
- `IssueReportDraftServiceTests` — one tool-free request with thinking Off,
  profile preflight, bounded execution, timeout/cancellation, no retry, and no
  fallback.
- `IssueReportSmartInputTests` — drafting and recording state: immediate busy
  state, duplicate-click suppression, atomic field replacement, guarded
  restoration, cancellation and dismissal, stale results, permission pending
  versus capture, exactly one transcription on Stop or automatic completion,
  append-not-replace, retained-audio retry, and target changes.
- `IssueReportComposerTests` — atomic generated-draft application and the
  one-step, edit-guarded restoration on the composer.
- `IssueReportWiringTests` — the view-local glue: text-editor paste ownership
  (including the smart-input box), the glow/permission distinction, accessible
  mic labels and status copy, the companion-naming preparation notice, and the
  DEBUG-only UI fixture gate.
- `IssueReportSmartInputUITests` (Mac UI) — both report kinds with plain
  English alone; immediate progress and disabled busy controls; generated
  fields remain editable; no recorder sheet or playback UI while the inline
  control records and stops; transcript appended to the smart input with the
  fields untouched; recoverable failure and one-click retry; and manual
  reporting with an unsupported drafting companion.
- Portable Python `tests.test_issue_report_drafts` — server-side validation,
  the owned charter, the exact stdin payload, execution flags, the 60-second
  cap, and one-shot continuation/promotion refusal.

Run the repository commands in [docs/code-factory.md](code-factory.md#verification)
for the exact suites. A passing run proves only the fixture-backed behavior; it
is not evidence that any installed build or real provider works.

### Synthetic manual checklist

Run this only on the exact built revision with disposable synthetic machines
and data. Never use production hosts, credentials, real conversations, or real
personal text in screenshots or reports. These checks were **not performed** by
the code or tests; do not report them as passing merely because the automated
suites are green.

| Check | How | Expected |
| --- | --- | --- |
| Real microphone glow | Grant the disposable Mac microphone access, click the inline mic, then Stop | The glow starts when capture actually begins and ends when it stops; no recorder sheet, waveform, timer, or playback panel appears; the status and accessible label change with the state. Deny permission once and confirm the actionable message and that nothing is retained. |
| Configured transcription | With `[providers.transcription]` configured only on the selected companion, record a short synthetic phrase and Stop | Exactly one request to that companion; the transcript appears in the smart-input box; the Title and Description stay untouched; no draft or filing starts by itself. Repeat on a companion without transcription configured and confirm the actionable error, preserved typed text, and the in-sheet retry/discard choice. |
| Generated writing quality | With Pi and a usable default model on the selected companion, type a plain-English bug and feature request and press **Draft with AI** | The title is concise, the body is structured for the kind, and every concrete detail in the source is preserved without invented facts. The result is editable; **Restore previous** puts back the prior fields once and only while nothing edited them. |
| Older companion | Point the sheet at a companion that does not advertise `issue-report-draft-v1` | Only **Draft with AI** is disabled with upgrade guidance; manual Title/Description, attachments, and submission still work; no drafting request is sent. |
| Minimum sheet size | Shrink the sheet to its minimum size and use the smart input, controls, attachments, and File report | Nothing overlaps or is unreachable; the sheet scrolls instead of clipping controls. |
| Larger text | Raise the app text-size preference and repeat the smart-input flow | Labels, status, editor text, notices, and buttons scale without clipping or overlap, and the controls stay reachable. |
| VoiceOver | With VoiceOver on, open the sheet and walk the smart-input section | The editor, mic/stop control, progress status, notices, **Draft with AI**, and **Restore previous** are announced with their state; recording state is understandable without seeing the glow. |
| No publication before **File report** | Draft, dictate, and edit with a companion attached but do not press **File report** | No issue, comment, or attachment appears on GitHub; only **File report** submits the reviewed fields. |

### Evidence status

No synthetic manual checklist record has been captured for the revision under
review, and no installed behavior or provider health is claimed. The final
validation owner records the checklist privately outside Git for the delivered
revision; until then those checks remain **unperformed**, and delivery stays
gated.

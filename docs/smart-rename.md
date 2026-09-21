# Smart Rename on Mac

Smart Rename gives a chat a short, contextual title. On Mac it is the shared
naming path for three targets:

- a workspace pane (Pi or shell), renamed through the companion so every client
  sees the new label;
- a color-group label in the sidebar, stored locally on this Mac;
- a HUD chat title override, stored locally on this Mac and carried into saved
  HUD history.

All three use one bounded, separate, enforced tool-free naming run. The
companion executes the dedicated `smart-rename-v1` profile with `--no-tools`
and no extension, so naming can never read the machine or take an action, even
if untrusted context text tries to steer the model into it. Naming never
submits a prompt to the source agent or shell and never continues the
conversation. The supplied context is treated as untrusted data.

## Preferences and defaults

**Settings → Agents → Smart Rename** exposes:

- **Model list from** — the companion whose catalog is browsable in Settings.
  This only changes what the picker shows; it does not choose the execution
  machine.
- **Smart Rename model** — an empty value means **Same as Agent model** (the
  Agent/Quick Chat model preference), then the execution machine's Pi default.
- **Smart Rename thinking level** — defaults to **Low**, matching earlier
  releases.

These defaults are unchanged from earlier releases. An explicit model or
thinking level is honored exactly; the saved preference is never rewritten by a
rename, and changing Smart Rename never changes Agent, HUD, Vision, or Notes
preferences.

## Strict selection policy

A rename checks the exact companion that will execute it. It fetches that
companion's model catalog and resolves the effective selection — the explicit
Smart Rename model, otherwise the Agent model, otherwise the companion's
declared default — against that catalog. A missing or failing selection is
reported for correction; it is never replaced with another model or machine.

| Condition | Result |
| --- | --- |
| A non-blank explicit or inherited selection is not offered by the execution companion | The rename stops before any naming request. The model is reported by name along with the companion, and the message points to Settings or to configuring that provider on that companion. |
| No effective selection and the companion declares a default missing from its own catalog | The rename stops before any naming request and reports the broken default. |
| The catalog cannot be read (transport, cancellation aside, or `ok: false`) | The rename stops before any naming request and reports that the companion's models could not be read. |
| The catalog decodes but lists no models | The rename stops before any naming request and reports that the companion's Pi installation advertises no models. |
| A model the catalog marks specifically as non-reasoning is paired with a thinking level above **Off** | The rename stops before any naming request and reports the incompatibility, suggesting **Off** or a reasoning-capable model. |
| The naming request starts but the provider, model, or run fails, times out, or returns invalid output | The rename reports the model, thinking level, and companion that executed it, explains the failure, and directs the user to Settings or that companion's provider configuration. No partial title is applied and no retry or replacement occurs. |

Strictness details:

- **Off** is always permitted. Every other selected level passes through
  unchanged, including levels above what a provider may support.
- The catalog exposes only a per-model reasoning flag, not effort ranges.
  Unknown capability is never guessed: only an explicit `reasoning: false`
  model is treated as known-incompatible.
- A catalog is not proof of provider credentials, quota, or service health. A
  listed model can still fail to start, and exactly one naming request is then
  attempted.
- Cancellation passes through as cancellation: the current title stays and
  nothing is mutated.
- Failures leave pane titles, color labels, HUD titles, and saved preferences
  untouched, and clear the busy state so the action can be retried.
- Invalid output (not a JSON `title` object, empty after trimming, longer than
  80 characters, or containing control characters) is reported through the same
  actionable execution-error formatter as a run failure, naming the model,
  thinking level, and companion without echoing the raw model output back.

## Tool-free execution

Smart Rename never relies on prompt wording to prevent tool use:

1. The app requests the dedicated `smart-rename-v1` profile, which the
   companion executes with `--no-tools`, no explicit extension, and a
   server-owned naming charter. A naming run accepts only a prompt, model, and
   thinking level; it refuses attachments, continuation, a custom system
   prompt, a working-folder change, or supplied context. The companion also
   refuses to continue or promote the stored naming run itself, so its one-shot
   session can never be reused as a tool-enabled chat.
2. Before dispatching, the app reads that companion's `/agent-runs/capabilities`
   and requires the advertised profile. A companion that does not advertise it
   is never sent the naming ask — an older companion would route the unknown
   profile to a contextual-question path with different tool access, so the app
   fails actionably instead and asks for the companion update.
3. The client context prompt still instructs the model to treat the text as
   untrusted data and to return only JSON, but that wording is defense in depth,
   not the enforcement boundary. Server-enforced no-tools execution is.

## Which machine executes a rename

The rename resolves the catalog and runs the ask on the machine that owns the
target:

- a pane runs on that pane's companion;
- a HUD chat runs on that chat's selected companion;
- a color-group label runs on the machine of the first successfully sampled
  controllable pane, not the primary or browsed catalog machine.

The **Model list from** picker never redirects a rename. Two companions that
advertise different model catalogs resolve independently: a model offered by one
companion may be missing on another, and the rename on that other companion
fails actionably instead of substituting its default.

## Context sources and bounds

Naming uses the first readable source and never requires an established
conversation:

1. **A matching Pi conversation** — when the pane declares a semantic session,
   its snapshot provides the original goal plus recent turns, with tools,
   images, and private reasoning excluded. Individual messages are bounded to
   1,500 characters and the total input is capped at 16,000 characters.
   Whitespace-only user and assistant messages are omitted before a source is
   chosen, so a blank snapshot falls through instead of blocking terminal or
   metadata context. A snapshot that is unavailable, empty, or declares a
   different session is treated as no conversation rather than blended into
   this pane's title.
2. **An acknowledged submission** — a successfully submitted prompt is merged
   ahead of a lagging snapshot, so a pane or HUD chat can be named from the
   prompt alone before any assistant response. Failed submissions are never
   used, and a cached prompt is only considered for the same machine, pane,
   terminal, workspace, tab, session, and connection generation. The prompt is
   only skipped when the snapshot already contains that complete `User:` turn:
   a shared prefix, a partial line, or the same words inside assistant text are
   not treated as the same turn, so the newest prompt is preserved instead of
   risking omission.
3. **Bounded terminal output** for shell or other nonsemantic panes — the last
   160 lines within the final 128,000 characters of output, with ANSI/CSI/OSC
   escape sequences and control characters stripped. It is labeled as untrusted
   terminal text.
4. **Pane, tab, workspace, and working-folder metadata** — pane label/title,
   terminal title, session title, workspace label, tab label, and working
   folder, each bounded to 200 characters.

HUD chats have their own transcript path: the first and most recent exchanges
(when more than nine exist, the first plus the last eight), with whitespace-only
prompts and responses omitted. Each message is bounded to 1,500 characters and
the total to 16,000 characters.

Color groups sample up to six panes, preferring one pane per tab in
deterministic order, run each sampled pane through the same pane context path,
compact each pane to 3,000 characters (keeping the beginning and end, with the
middle omitted), and cap the combined group input at 24,000 characters. One pane
with unreadable context is skipped so it cannot hide the rest; the group still
needs at least one readable pane.

If none of the available sources has readable text, the target keeps its title
and the UI reports that there is not enough context yet. It never demands a
conversation or assistant reply.

## Guards, stale results, and persistence

- Duplicate renames for the same target are refused while one is running.
- Cancellation keeps the previous title and performs no mutation.
- Streaming responses, tool progress, and completion for the submitted turn do
  not invalidate a rename; a reply arriving while naming is in flight does not
  discard the result.
- A manual title edit, a replaced terminal or session, a changed machine, a
  removed or ended HUD chat, a changed color-group membership, a different
  prompt/turn, or a replaced history root prevents a stale result from being
  applied. The user's newer change wins.
- A newer accepted submission on the target pane, or on a sampled pane of the
  color group, invalidates a naming result that read the older context. The
  captured submission revision is rechecked immediately before mutation, so the
  late title is rejected while assistant streaming, tool activity, and
  completion for the already-named submission do not invalidate it.
- Pane naming captures the pane identity, connection generation, rename
  revision, and submission revision before the model, context, and AI work,
  rechecks them immediately before the server mutation, and reports a conflict
  if anything changed.
- Color-group naming captures each sampled pane's identity, connection
  generation, rename revision, and submission revision before loading that
  pane's context, then rechecks all of them together with the shared label
  revision and current membership before applying the label. A prompt accepted,
  a manual rename, or a connection change while context is loading discards the
  stale result.
- Invalid output (not a JSON `title` object, empty after trimming, longer than
  80 characters, or containing control characters) performs no mutation and
  reports the failure through the actionable execution-error formatter, naming
  the model, thinking level, and companion without echoing the raw output.
- After a successful pane mutation, the app refreshes once and reports the
  server's title. If that refresh fails, the rename is still reported as
  completed with the refresh problem noted, rather than guessed or repeated.
- A HUD title created before its first run has a durable history identity is
  remembered against that exact chat and submission placeholder and attached
  when that submission's accepted run becomes known, so it survives relaunch,
  dismissal, and reopening from history without another chat or a later turn
  claiming it.

Persistence differs by target:

- **Pane labels are renamed through the companion.** The title is server state
  for that pane, so every connected client sees it. It is not a local-only
  label.
- **Color-group labels and HUD title overrides remain local app state on this
  Mac.** They are stored in this Mac's preferences and are not synced to
  other clients. HUD history titles are keyed to the saved conversation's
  machine and root identity, and a title still waiting on its first accepted
  run is keyed to the owning chat and submission placeholder, with bounded
  saved and pending history-title stores.

## Compatibility

Smart Rename reuses existing endpoints:

- the Pi semantic snapshot endpoint for conversations;
- the pane output endpoint for shell context;
- the agent-model catalog endpoint for availability;
- the existing headless-agent run, pane rename, and HUD chat APIs.

The execution companion must advertise the `smart-rename-v1` profile from
`/api/v1/agent-runs/capabilities`. That profile is the enforced tool-free
naming path in the companion server, and it is the only profile Smart Rename
ever requests. An older companion does not advertise it: the app stops before
dispatch, sends no naming request, keeps the current title, and reports that the
companion server must be updated. The companion refuses naming requests that
carry attachments, continuation, a custom system prompt, a working-folder
change, or supplied context. This adds a capability, not a configuration or
migration, and changes no companion credentials, providers, or machine
settings. iOS and the web client are unchanged.

Providers must work in each execution companion's environment; a companion that
cannot return a usable model list produces the actionable catalog error above.

## Verification

### Deterministic automated suites

The fixture-backed suites use fake runners and synthetic HTTP fixtures; they do
not contact a live provider. They cover:

- `SmartRenameModelRoutingTests` — strict resolution against one exact machine,
  differing companion catalogs, missing explicit and inherited selections,
  machine defaults, incompatible and Off effort, catalog failures, execution
  error wrapping, and cancellation passthrough.
- `SmartRenameExecutionTests` — the HTTP-backed execution seam: exact model,
  effort, tool-free profile, prompt, and context in the dispatched request; a
  companion that does not advertise the tool-free profile receiving no request;
  shell-pane naming; an advertised model that fails at execution; no partial
  mutation; and no dispatched request for a missing selection.
- `SmartPaneRenameTests` — prompt-only pane naming, empty and lagging
  snapshots, shell and metadata fallbacks, unreadable, whitespace-only, and
  mismatched snapshots, no-context reporting, stale-target, manual-edit,
  newer-submission, and strict selection failures, and invalid-output
  reporting.
- `SmartPaneTitleTests` — parsing, bounds, metadata, escape-free terminal
  context, and whitespace-only snapshot messages.
- `SmartChatColorRenameTests` — color-group context, deterministic routing,
  races, and strict selection failures.
- `HerdrHudChatsTests` — HUD prompt-only naming, response/completion races,
  stale-result protection, invalid-output reporting, exact pending-title
  ownership across two chats with matching prompt prefixes and reversed
  acceptance, and history-title persistence including pending titles and
  relaunch/reopen.
- `AgentControlSmartRenameTests` and `AgentControlRoutingTests` — agent-control
  rename receipts, execution and invalid-output failures, and shell-pane
  routing.
- The portable Python suites prove the companion invocation directly: the
  naming profile runs Pi with `--no-tools`, no `--tools` flag, no explicit
  extension, a fixed naming charter, and source context on stdin, and the HTTP
  route advertises and dispatches `smart-rename-v1` while rejecting naming
  requests that carry continuation, attachments, overrides, or context.
- `AgentModelSettingsStoreTests` — unchanged defaults and inheritance,
  persistence across store recreation, and no unrelated-preference rewrites.
- `SettingsRenderTests` — both Smart Rename controls, the saved unavailable
  selection, the incompatible-effort warning, and strict-policy copy.

The required final gate is the exact-SHA **Verify** run, which owns
`herdr-harness-macTests` (including the suites above), the portable Python and
Node suites, the standalone-install check, the gitleaks history scan, and
`python3 scripts/check-public-source.py` (run with `--staged` inside Verify).
The complete manual matrix and smoke-check procedure below are handed to that
single final validation owner; tests are authored alongside the code but are not
run incrementally or duplicated locally by habit. A passing Verify run proves
the fixture-backed suites only: it is not evidence that an installed build
shows the behavior or that any real provider works. Those records come from the
private installed-UI matrix and per-companion execution checks below, and
delivery stays gated until they exist for the delivered revision.

### Installed-UI evidence

The single final validation owner runs the synthetic matrix on the exact built
revision of the Mac app paired with the tested companion revision, using only
disposable synthetic machines and data. One private report outside Git records,
for every scenario, the app/source revision, the companion revision, whether the
companion advertises the tool-free `smart-rename-v1` profile, the effective
model and thinking level, the observed result, and any failure. The record must
cover at least:

1. **Settings controls** — the Smart Rename model and thinking controls appear,
   an empty model inherits the Agent model then the execution machine's Pi
   default, thinking defaults to Low, and the choices survive a relaunch.
2. **Prompt-only pane naming** — submit a prompt to a fresh disposable Pi pane
   and rename it before any reply appears; the submitted prompt alone produces a
   title, and a reply arriving during naming does not discard it.
3. **Shell naming** — a controllable disposable shell pane without a Pi session
   is named from bounded terminal output and pane/workspace metadata, with no
   input submitted to the shell.
4. **HUD naming** — the same prompt-only check, plus title persistence after
   relaunch, removal, and reopening from history.
5. **Color-group naming** — a color group with readable synthetic context is
   named on the machine of the first successfully sampled controllable pane.
6. **Strict failures** — a missing explicit or inherited model, an unreadable
   or empty catalog, a non-reasoning model paired with an effort above Off,
   and a companion that does not advertise the profile each stop before
   dispatch, keep the existing title or label, leave the saved selection
   unchanged, and show the actionable error.

A green exact-SHA Verify run is not a substitute for this record. A companion
that is inaccessible remains **unverified**, and a check that was not performed
stays explicitly **unperformed**; neither may be reported as passing, fixed, or
working. Delivery — release notes, upload, or companion publication — stays
gated until both this private installed-UI matrix and the per-companion
smoke-check results below are recorded for the delivered revision. Do not
change credentials or providers, and do not deploy companion servers, merely
to produce this evidence.

### Synthetic manual matrix

Run this only with disposable, synthetic machines and data. Never use production
hosts, credentials, or real conversations. The fixture tests above are not
evidence that any real provider works; only the smoke check below records actual
execution.

| Scenario | Setup | Expected |
| --- | --- | --- |
| Successful early naming | Submit a prompt to a fresh, disposable Pi pane or HUD chat and rename before any reply appears | The submitted prompt alone produces a title; later response text, tool steps, and completion do not discard it |
| Shell context | A controllable disposable shell pane with no Pi session and recent output | The title is built from the bounded terminal tail and pane/workspace metadata; escape sequences do not leak in and no input is submitted to the shell |
| Unavailable snapshot | A Pi pane whose snapshot endpoint fails, returns empty, or names another session, while terminal output exists | Naming uses the terminal output (then metadata); another session's transcript is never imported |
| Two differing catalogs | Two disposable companions advertising different model catalogs; name a target on the second | Only the target machine's catalog is fetched; the ask runs there with the effective selection and effort |
| Missing explicit model | Save a Smart Rename model that the execution companion does not offer | No naming request is dispatched; the title, label, and saved preference are unchanged, and the error names the model and companion and points to Settings or that provider |
| Missing inherited model | Leave Smart Rename empty with an Agent model the execution companion does not offer | Same failure as above; the rename does not silently fall back to the machine default, and the Agent preference is unchanged |
| Advertised-but-failing provider | The catalog lists a model, but its provider fails to start or the naming run times out | Exactly one request is attempted; no title mutation; the error names model, effort, and companion and directs to Settings or provider configuration |
| Incompatible effort | A catalog model marked non-reasoning with a saved thinking level above Off | The rename stops before dispatch, suggests Off or a reasoning-capable model, and keeps the saved effort; selecting Off succeeds |
| Incompatible companion | A companion that does not advertise `smart-rename-v1` from its agent-run capabilities endpoint | No naming request is dispatched; the title stays and the error names the companion and says its server must be updated |
| Unreadable or empty catalog | The execution companion's catalog is unreachable, unsuccessful, or empty | The rename stops before dispatch, keeps the current title, and shows the actionable catalog error; no preference is rewritten |
| Manual-edit race | Edit a title, color label, or HUD title while its naming run is in flight | The manual value wins; the late result is not applied |
| Newer submission race | While a naming run is in flight, submit another prompt to the same pane or to a sampled pane of the color group | The late title is rejected for the newer context; a response or completion for the already-named submission is not treated as invalidation |
| Stale target | Replace the terminal or session, remove or end the HUD chat, or change color-group membership while naming is in flight | The late result is discarded; the replacement or newer state is untouched |
| HUD history persistence | Rename a HUD chat, relaunch, and remove/reopen it from history; include a title created before the first run was accepted, and a second chat with a matching prompt prefix accepted first | The title is retained locally through relaunch and reopening and attaches only to its own submission; the other chat never inherits it |
| Color-group routing | Shell-only panes sharing one color, on a machine that can control them | The label is named from bounded terminal/metadata context and runs on the machine of the first successfully sampled controllable pane |

### Required per-companion smoke check

Per-companion functionality claims require actual execution evidence; catalog
membership alone is not proof, and every supplied provider test is a synthetic
fixture. Delivery is not complete until this check has been recorded for every
configured execution companion. At the frozen source revision, the single final
validation owner runs one authorized synthetic smoke check per configured
execution companion (the exact-SHA Verify run owns the automated suites):

1. Confirm the companion may be used for a synthetic check and that a
   disposable pane, HUD chat, or color group with synthetic text is available.
2. Record the private evidence fields: app/source revision, companion revision,
   whether the companion advertises the tool-free `smart-rename-v1` profile,
   the effective selected model and thinking level, the observed result, and any
   failure.
3. Run Smart Rename with an explicit selection the companion offers, then with
   the default **Same as Agent model** path. Confirm the resulting title reflects
   the synthetic context and that the dispatched values match the recorded
   selection.
4. If the selection is missing from that companion, or the provider fails,
   record the failure and correct Settings or the provider only when that
   correction is separately authorized. Never report a per-companion result as
   fixed, working, or verified without an observed synthetic result.
5. A companion that is inaccessible remains **unverified**, not failed and not
   passing. A check that was not performed remains explicitly unperformed. The
   validation owner reports both cases; neither may be summarized as working.

The smoke check contacts only the named disposable companions. Keep evidence
reports private and outside Git: no hostnames, credentials, personal paths, or
captured conversation data. Record only the fields above and generic companion
identifiers.

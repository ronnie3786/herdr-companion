# Smart Rename on Mac

Smart Rename gives a chat a short, contextual title. On Mac it is the shared
naming path for three targets:

- a workspace pane (Pi or shell), renamed through the server so every client sees
  the new label;
- a color-group label in the sidebar, stored locally on this Mac;
- a HUD chat title, stored locally and carried into saved HUD history.

All three use one bounded, separate `.ask` run. Naming never submits a prompt to
the source agent or shell, never continues the conversation, and never calls
tools. The supplied context is treated as untrusted data.

## Preferences and defaults

**Settings → Agents → Smart Rename** exposes:

- **Model list from** — the companion whose catalog is browsable in Settings.
  This only changes what the picker shows; it does not choose the execution
  machine.
- **Smart Rename model** — an empty value means **Same as Agent model** (the
  Agent/Quick Chat model preference), then the execution machine's Pi default.
- **Smart Rename thinking level** — defaults to **Low**, matching earlier
  releases.

An unavailable saved model is not rewritten. Renaming falls back to the
execution machine's declared default and shows a notice. A model the catalog
marks as non-reasoning receives **Off** for that run without changing the saved
thinking level. Unrelated Agent, HUD, and Notes preferences are untouched.

## Which machine executes a rename

The rename resolves the model catalog and runs the ask on the machine that owns
the target (the pane's machine, or the HUD chat's selected machine). A
color-group label runs on the machine of the first successfully sampled
controllable pane, not the primary or selected catalog machine.

Because of that:

- A model offered by one companion may be unavailable on another. The saved
  preference stays as configured; the notice explains the fallback.
- A model catalog is not proof of provider credentials, quota, or service
  health. The provider must be configured and working in the environment of the
  companion that executes the rename.
- Catalog failures (transport error, `ok: false`, an empty list, or a declared
  default missing from its own list) stop before any request is dispatched and
  leave the existing title in place with an actionable message.

## Context sources and bounds

Smart Rename uses the first readable source:

1. **A matching Pi conversation** — the original goal plus recent turns, with
   tools, images, and private reasoning excluded. Individual messages are
   bounded and the total input is capped at 16,000 characters.
2. **An acknowledged submission** — a successfully submitted prompt is merged
   ahead of a lagging snapshot, so a pane or HUD chat can be named before any
   assistant response. Failed submissions are never used.
3. **Bounded terminal output** for shell or other nonsemantic panes — the last
   160 lines (scanned within a 128,000-character tail) with ANSI/CSI/OSC escape
   sequences and control characters stripped.
4. **Pane, tab, workspace, and working-folder metadata** — labels and paths,
   each bounded to 200 characters.

Color groups sample up to six tab-fair, deterministic panes, compact each pane's
context to 3,000 characters, and cap the combined group input at 24,000
characters.

If none of these sources has readable text, the target keeps its title and the
UI reports that there is not enough context yet; it never demands a conversation
or replies.

## Guards and persistence

- Duplicate renames for the same target are refused while one is running.
- Cancellation keeps the previous title and performs no mutation.
- Streaming responses, tool progress, and completion for the submitted turn do
  not invalidate a rename.
- A manual title edit, a replaced terminal or session, a changed machine, a
  removed or ended HUD chat, a changed color-group membership, a different
  prompt/turn, or a replaced history root prevents a stale result from being
  applied.
- A HUD title created before the first run has a durable identity is remembered
  against that submission and attached to the conversation when its accepted run
  becomes known; it survives relaunch and reopening from history.
- Pane and color-group labels and HUD titles persist locally on this Mac. They
  are not synced to other clients.

## Compatibility

Smart Rename reuses existing APIs:

- the Pi semantic snapshot endpoint for conversations;
- the pane output endpoint for shell context;
- the agent-model catalog endpoint for availability;
- the existing headless-agent run and pane/hud-chat mutation endpoints.

No new server capability, contract, or migration is introduced, so this is a
Mac-only change. The server-side endpoints must be present on every companion
that executes a rename; providers must work in each target companion's
environment. iOS, the web client, and the server contract are unchanged.

## Synthetic manual matrix

Run this with disposable, synthetic machines and data only. Never use production
hosts, credentials, or real conversations. The automated tests use fake runners
and synthetic HTTP fixtures; no live provider is contacted.

| Scenario | Setup | Expected |
| --- | --- | --- |
| Initial prompt | Submit a prompt to a fresh Pi pane or HUD chat and rename before any reply appears | The submitted prompt alone produces a title; later response text, tool steps, and completion do not discard it |
| Shell-only pane | A controllable shell pane with no Pi session and recent output | The title is built from the bounded terminal tail and pane/workspace metadata; escape sequences do not leak in |
| Streaming HUD | Rename a running HUD chat, then let the run complete while naming is still in flight | The late AI title still applies; the chat is not marked changed |
| Two catalogs | Two disposable companions advertising different model catalogs; name a target on the second | Only the target machine's catalog is fetched; the ask runs there with the configured thinking level |
| Fallback and error | Save a model the execution machine does not offer; then make its catalog unreachable or empty | Fallback uses that machine's default with a visible notice and no preference rewrite; catalog failure keeps the old title with an actionable message |
| Manual-edit race | Edit a title or color label while its naming run is in flight | The manual value wins; the late result is not applied |
| Persistence | Rename, relaunch, and remove/reopen the HUD chat from history | The title is retained locally, including a title created before the first run was accepted |
| Non-reasoning model | Make the execution machine's default a model marked non-reasoning, with a saved thinking level | The run receives **Off**; the saved thinking level is unchanged |

## Automated verification

The focused suites are:

```bash
xcodebuild -project herdr-harness-mac/herdr-harness-mac.xcodeproj \
  -scheme herdr-harness-mac -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test \
  -only-testing:herdr-harness-macTests/HerdrHudChatsTests
```

`SmartPaneRenameTests`, `SmartChatColorRenameTests`, and
`SmartRenameModelRoutingTests` cover the pane, color-group, and catalog
policies. The final validation owner runs the exact-SHA Verify suite and performs
the manual matrix above; these checks are not a claim that any real machine or
provider was exercised.

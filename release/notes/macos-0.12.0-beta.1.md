# Herdr Companion 0.12.0 Preview 1

## First Mate, one conversation per feature

Open **First Mate** in the Mac sidebar to keep a feature's goal, conversation, agents, documents and workflow together. Light and dark appearances are available. The main conversation stays focused while independent Pi sessions perform delegated work.

- The Overview shows the current goal and assignments. Agents and Documents expose exact saved sessions and producing evidence.
- Workflow offers timeline and graph views. Compact agent and document menus support multiple reviewers and attachments without filling the surface with every session.
- Each completed major stage waits for your plain-English direction. Internal work can run asynchronously within that stage, while explicit human gates still require a response.
- The companion service owns durable dispatch, automatic work logging, session health monitoring, bounded recovery and fresh-session handoffs. Closing the app does not stop managed work.
- Handoffs preserve the predecessor's transcript and checkpoint. A successor must acknowledge that checkpoint before editing. Branches and worktrees remain available for an explicit cleanup decision.

## Required server update

First Mate requires the matching companion server and bundled Pi extension from this release's source revision. The separate **companion-v0.12.0-beta.1** release provides the server package. Pi and a working model provider must already be configured on the companion host.

**The Mac updater installs only the Mac app.** It does not install the companion server, change Pi settings, or update iOS. Existing features continue to use the configured server; First Mate becomes available after the matching server package is installed. Follow the repository's independent server update instructions and preserve the existing private configuration, state and credentials.

First Mate starts with one companion host per feature, a configurable 150,000-token context handoff target, and up to eight managed workers. Optional stage-completion notifications require the operator's own Message Hub configuration. Managed skills must use the typed delegation tools for tracking; independently launched processes are not automatically adopted.

## Try it

1. Update through **Herdr Companion → Check for Updates…** with **Include preview builds** enabled in **Settings → App updates**.
2. After the matching server is installed, select its connection and open **First Mate → +**. Enter a feature goal and a project folder on that host.
3. Ask First Mate to start with a plan. Inspect the returned agents, documents and saved sessions, then give your next direction after the stage pauses.

The explainer under `docs/first-mate/explainer` includes three captioned reels with generated narration and captures of the implemented Mac UI. The reels use synthetic demonstration data; runtime validation is documented separately.

## Verification

The complete Mac unit target passed 1,106 tests across 165 suites. A deterministic test icon removes the test host's dependency on macOS IconServices without changing production HUD rendering. The Python suite passed 927 tests with one skip, and separate real Pi checks exercised planning, nested delegation, restart and implementation followed by review of the exact commit.

This is a signed experimental development preview, not a notarized Developer ID release.

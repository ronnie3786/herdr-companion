# macOS 0.19.0-beta.1

## Agent control for Mac Companion

- Adds the authenticated `herdr-control` JSON CLI for cross-machine chat, workspace, and tab discovery, exact-target inspection, resource management, and Mac navigation. Find work by ticket or text across configured machines, then open the exact conversation in a specific Mac receiver instead of assuming terminal focus changed the Companion UI.
- Open the exact workspace, tab, or pane; switch Chat/Terminal/Git/Skills and main app segments; use Back/Forward; and invoke cataloged actions: summaries, Smart Rename with explicit model choice, unread/color markers, HUD/Notes/Settings navigation, and workspace/tab/chat creation, renaming, starring, splitting, and closing.
- Every command returns a durable receipt with explicit success, failure, or unknown outcomes. Uncertain mutations are never blindly replayed; busy panes, replaced Pi sessions, offline receivers, and blocked editors are reported honestly.
- Discovery reports its source coverage and continuation cursors per source: live topology, saved HUD chats with real match excerpts, First Mate text and metadata, and verified Active Work ticket links. Closed standalone Pi archives and historic nested menus are explicitly not fully indexed.

Enable **Allow agent control** once in Settings. It is off by default. Commands within the user's authorization in the agent conversation do not require an additional Mac confirmation dialog; authentication, exact target/session checks, busy-state guards, and existing manual UI confirmations remain in place. See [the command guide](https://github.com/ronnie3786/herdr-companion/blob/macos-v0.19.0-beta.1/docs/agent-control.md) for setup, commands, receipts, and scope limits.

## Matching companion required

Install the [matching companion 0.19.0 preview](https://github.com/ronnie3786/herdr-companion/releases/tag/companion-v0.19.0-beta.1) on every machine that should advertise `agent-control-v1` and `discovery-v1`. The relay companion and the receiving Mac UI client are addressed separately, so a machine can relay discovery without running the receiver. The Mac updater does not install or restart companion services.

## Install safely

In **Settings → App updates**, enable **Include preview builds**, then choose **Herdr Companion → Check for Updates…**. Review the update and let Sparkle install and relaunch the app.

This preview uses Apple Development signing and is **not notarized**. It may require normal macOS approval on first installation; do not disable Gatekeeper or other protections. No live provider-quality test or server rollout is implied by this release.
# Agent control — unreleased

## Find work and bring it into the current Mac UI

- Adds the authenticated `herdr-control` JSON CLI for cross-machine chat/workspace/tab discovery, exact-target inspection, resource management and Mac navigation.
- A receiving Mac is addressed separately from the companion hosting the chat. Open the exact workspace, tab or pane, switch Chat/Terminal/Git/Skills and main app segments, and inspect command receipts instead of assuming terminal focus changed the Companion UI.
- Adds a discoverable action catalog for supported navigation, summary, Smart Rename, unread/color, HUD/Notes/Settings and workspace/pane operations. This is the core control interface, not yet every nested control in the app.
- Workspace/tab/chat creation and opening have separate results. A failed UI open does not create another resource. Exact-session checks, durable request receipts and explicit unknown outcomes guard retries.
- The matching Pi package adds concise CLI-discovery guidance to Herdr agent sessions.

## Setup and authorization

Enable **Allow agent control** once in Mac Settings. It is off by default. Commands within the user's authorization in the agent conversation do not require an additional Mac confirmation dialog. Manual UI confirmations, existing workflow human checkpoints, authentication, target validation and busy-state safeguards remain in place.

This feature needs the matching companion server and CLI advertising `agent-control-v1` and `discovery-v1`, plus the updated Mac app. The app's signed-feed updater does not install the server package or CLI. No update is published or installed merely by this source change.

## Verification guide

1. Search two synthetic machine fixtures with the same raw pane ID; select and inspect one result, then open it in one specific Mac receiver.
2. Switch Chat → Git → another segment, then Back/Forward. Confirm actual selection and retained drafts.
3. Create a workspace or chat with a stable request ID and open it; retry the same logical request without duplicating the resource.
4. Test an offline receiver, a replaced Pi session, a blocked editor, a lost acknowledgement and a server restart. None should be reported as successful navigation or blindly replay an uncertain mutation.
5. Inspect source coverage and the action catalog before using search or a submenu action. Closed standalone Pi archives and all nested UI controls are not fully covered in this update.

See [the command guide](../../docs/agent-control.md) for commands, setup, receipts and scope limits.

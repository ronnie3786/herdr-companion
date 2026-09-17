# Companion 0.16.0 Preview 1

## HUD chat working folders and cross-device history

- Accept and validate the optional working folder for saved HUD chat requests. Previously, Mac custom-folder requests were rejected immediately because the API did not accept `cwd`.
- Advertise `hudChatWorkingDirectory` so Mac and iOS can distinguish servers that support custom-folder chats. Resolve paths on the companion host and expose the canonical folder with saved HUD history and catalog entries.
- Preserve a conversation's original working folder on continuation. Missing directories and invalid requests fail explicitly; no implicit directory creation, folder change, or fallback to home.
- Keep the existing authenticated `hud-chat-v1` history/continuation contract, so the matching iOS app and Mac HUD use the same saved conversations without moving them between machines. Existing contextual-question scope and retention behavior are unchanged.

## Separate server installation required

This is a companion **server package**, not a Mac or iOS installer. The Mac signed updater does not install it, restart services, or update the phone. Updating a checkout alone does not change an installed server runtime.

Use Python 3.11 or newer and the separately installed Herdr terminal and Pi. Before changing services, take a consistent private state backup, retain the old runtime/service definitions, and preserve the private TOML, credentials, Pi configuration, and state locations. Saved HUD conversations and Pi sessions live under the configured `agent-runs` state; do not delete or replace that directory.

Follow [the server update procedure](https://github.com/ronnie3786/herdr-companion/blob/companion-v0.16.0-beta.1/herdr_harness/README.md#update-the-server): install the released wheel in a new versioned environment, validate configuration and its packaged installation, then explicitly switch only the intended companion service. Update its matching CLIs and Pi package path as described there, preserving unrelated packages and worker settings. Verify authenticated health, terminal connectivity, notes, HUD history, and enabled workers before retiring the previous runtime.

Install on every companion machine where custom-folder chats should work. No direct server installation or cutover is performed merely by publishing this package. Older native clients remain compatible; older `hud-chat-v1` servers continue to support saved history and home-folder chats, but require this update for new custom-folder submissions.

## Verify after updating

With both native clients paired to the same machine, create a HUD chat in an existing folder with a space in its path, then read and reply from the other client. Confirm the original folder and all turns remain visible. Missing folders should produce a clear error without dropping the draft. Two clients replying at once must not fork the thread. New chat or leaving the screen must not delete saved history.

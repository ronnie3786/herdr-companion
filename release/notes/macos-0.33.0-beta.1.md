# Herdr Companion 0.33.0 Preview 1

Agents can recognize when they are running in Herdr Companion and find its own documentation without loading a manual into every prompt.

- Workspace chats, independent saved HUD chats, and ordinary Companion agent runs receive a short description of their context and where to look when asked about the app.
- First Mate coordinators, workers, and advisors receive their validated feature/role context and an on-demand guide to tracked delegation, Documents, service monitoring, handoffs, and human checkpoints.
- The new offline `herdr-docs` CLI provides overview, control, First Mate, and API references. Agents consult current CLI help and live action catalogs rather than assuming every installation supports every action.
- Existing permissions, ASK/no-tool restrictions, project trust, and workflow gates remain unchanged. Unmanaged Pi sessions and restricted naming/question/brief helpers are not relabeled as ordinary Companion chats.

This preview preserves the First Mate Git workspaces and pinned windows from 0.32.0 Preview 1 and the latest reviewed Code Factory changes.

## Try it

In a new Chat or HUD conversation, ask **“What can you do in Herdr Companion, and where is its documentation?”** In First Mate, ask **“What is First Mate, and how do you manage this feature’s workers?”** You can also run `herdr-docs list` or `herdr-docs read first-mate` directly.

## Required companion update

Awareness runs on the companion host and in its Pi package, not solely in the native Mac app. Install **companion 0.33.0b1**, its CLIs, and its bundled Pi package on each agent host. The Mac updater does not install the server package. Existing clients remain compatible; the awareness change introduces no state migration or iOS app update.

New sessions use the updated package. For an existing idle Pi session using the global package, use `/reload`. Sessions launched with an explicit old extension path need a safe exit/resume without that override. Do not interrupt active work just to reload. First Mate receives current guidance on new dispatches after its server/package update; running turns keep their existing runtime.

Install this Mac preview through **Herdr Companion → Check for Updates…** and the signed release feed. The app’s bundle and Keychain identities are unchanged. See [agent awareness](https://github.com/ronnie3786/herdr-companion/blob/macos-v0.33.0-beta.1/docs/agent-awareness.md) for coverage and rollout details.

# macOS 0.16.1-beta.1

## Leaner conversation handoffs

- Drag a Pi chat onto another prompt on the same machine, or use **Add to current prompt**, to keep the removable conversation chip without copying the source transcript into the destination prompt.
- Herdr pins the source by its workspace ID and current Pi session ID. When you send, the receiving agent gets the exact `herdr-session-context get --workspace-id … --session-id …` command before your current request.
- Fetched session context is explicitly prior conversation data, never instructions that override the current request. The Mac app does not fetch, store, freeze, serialize, or embed the source transcript, title, path, turn count, or completion state in the sent prompt.
- Cross-machine conversation references are unavailable in this version. A direct attempt is rejected instead of attaching a reference that the destination machine cannot resolve.
- The source session is still validated when the chip is added. Duplicate references are ignored, failed sends preserve the chip for retry, and successful sends remove only the references that were submitted.

## Compatibility and installation

Install through **Herdr Companion → Check for Updates…** with **Include preview builds** enabled. This preview uses Apple Development signing and is not notarized; signed update verification remains enabled.

Conversation references require the matching Herdr companion 0.16.1b1 on that machine, advertising `pi-session-context-v1`, plus the installed `herdr-session-context` CLI. The Mac app checks the capability before staging a reference and asks you to upgrade when it is unavailable. The Mac updater does not install the companion package or CLI and does not restart or cut over a companion server.

## Try it

On one machine, open a Pi chat and drag a different sidebar chat onto its prompt. Add an instruction and send. The destination agent should receive the exact `herdr-session-context` locator command and safety boundary before your request, without source transcript content or display metadata embedded in the prompt. Remove a chip with its accessible remove button, or retry a failed send without restaging it.

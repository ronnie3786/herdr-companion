# macOS 0.16.1-beta.1

## Leaner conversation handoffs

- Drag a Pi chat onto another prompt, or use **Add to current prompt**, to keep the same removable conversation chip without copying the source transcript into the destination prompt.
- Herdr now passes only the source workspace ID and current Pi session ID. The receiving agent is told to fetch that session’s context from Herdr before handling your request, keeping long or active chats out of the destination agent’s initial context window.
- The source session is still validated when the chip is added. Duplicate references are ignored, failed sends preserve the chip for retry, and successful sends remove only the references that were submitted.

## Compatibility and installation

Install through **Herdr Companion → Check for Updates…** with **Include preview builds** enabled. This preview uses Apple Development signing and is not notarized; signed update verification remains enabled.

This is a Mac-only client change and needs no companion server, Pi extension, iPhone, or iPad update. The Mac updater does not install or restart the companion server.

## Try it

Open one Pi chat, drag a different sidebar chat onto its prompt, add an instruction, and send. The destination agent should receive the source Herdr workspace ID and Pi session ID before your request, without the source transcript, title, path, turn count, or completion state embedded in the prompt.

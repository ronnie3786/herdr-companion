# macOS 0.15.0-beta.1

## Bring an existing chat into your next prompt

- Drag any Pi chat from the Mac sidebar into another chat’s prompt to attach its conversation as context. Herdr freezes the visible user and assistant discussion into a removable conversation chip, so the destination agent receives the earlier decisions together with your new request.
- Right-click a sidebar chat and choose **Add to current prompt** for the same handoff without dragging.
- Conversation references stay with each unsent prompt while the app is running, survive switching between panes, and are removed only after a successful send. Duplicate references are ignored, and failed sends keep the chips available for retry.
- Referenced transcripts are clearly separated from the current request, exclude hidden thinking and tool activity, and identify partial captures when a source was still running, already truncated, or too large for one prompt.

## Compatibility and installation

Install through **Herdr Companion → Check for Updates…** with **Include preview builds** enabled. This preview uses Apple Development signing and is not notarized; signed update verification remains enabled.

This is a Mac-only client feature and needs no companion server, Pi extension, iPhone, or iPad update. The Mac updater does not install or restart the server.

## Try it

Open one Pi chat, drag another chat from the sidebar onto its prompt, and confirm the conversation chip appears. Add a new instruction and send. The destination agent should receive the referenced discussion followed by your current request. Remove the chip before sending to exclude it, or retry after a failed send without dragging it again.

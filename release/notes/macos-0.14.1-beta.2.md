# macOS 0.14.1-beta.2

## Ultra-compact HUD glow

- Hover the HUD orb and use the new top-left compact control to reduce the floating HUD to a 20-point status glow. This is a minimize mode, not Hide HUD, and the preference persists on this Mac.
- Hover the glow to temporarily restore the standard collapsed HUD, including agent and HUD-chat bubbles, results, notes, and voice controls. Move away to return to the glow, or click the same top-left control while previewing to keep the standard HUD visible.
- The glow is yellow while any work is running, green when completed work is waiting to be read, and Herdr purple when idle. Blocked or failed work keeps the alert color, and offline state remains visibly muted.
- Explicitly opened chats, note editors, Quick Voice, and voice-reply cards remain open and usable instead of collapsing underneath the pointer.

## Compatibility and installation

Install through **Herdr Companion → Check for Updates…** with **Include preview builds** enabled. This preview uses Apple Development signing and is not notarized; signed update verification remains enabled.

This is a Mac-only presentation change and needs no companion server update. The Mac updater does not install or restart the server, update Pi extensions, or update iPhone or iPad.

## Try it

Hover the HUD orb, click the new top-left compact control, and move away. Confirm the HUD rests as a tiny glow whose color follows current work. Hover the glow to inspect the complete collapsed HUD and its agents, then move away to minimize it again. Hover once more and click the compact control to return to the standard persistent HUD.

# macOS 0.14.1-beta.3

## Refined ultra-compact HUD

- The 20-point compact status signal now uses a restrained shadow instead of the previous oversized glow.
- The signal stays centered on the normal HUD orb’s position, so hovering between compact and standard views no longer makes the status indicator jump toward the top-right.
- The top-left compact control now has a clear selected appearance whenever ultra-compact mode is enabled, including while hover temporarily previews the standard HUD.
- Turning compact mode on collapses the HUD immediately rather than waiting for the pointer to leave. Hover preview, persistent mode selection, status colors, and protection for explicitly opened chat, note, and voice surfaces remain unchanged.

## Compatibility and installation

Install through **Herdr Companion → Check for Updates…** with **Include preview builds** enabled. This preview uses Apple Development signing and is not notarized; signed update verification remains enabled.

This is a Mac-only presentation change and needs no companion server update. The Mac updater does not install or restart the server, update Pi extensions, or update iPhone or iPad.

## Try it

Hover the HUD orb and click the top-left compact control. Confirm the control highlights and the HUD immediately becomes a subtle centered status dot. Hover the dot and verify the restored orb stays centered over it, then move away to return to the compact signal.

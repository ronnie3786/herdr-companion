# macOS 0.14.0-beta.2

- Finished notifications now use the green completion signal on both HUD session bubbles and the collapsed orb.
- The numerical attention overlay no longer covers the orb. The count remains available to accessibility tools.
- Blocked and failed work keeps its red alert treatment.
- Clanking groups in the main chat now start collapsed, never open themselves after a tool failure, and keep the reader’s chosen disclosure state during live updates. In the collapsed group header, only the failure count is red; the surrounding chrome remains neutral.

## Compatibility

This release delivers the Mac change. Matching iOS source is included for the next separately delivered iOS app build; installing this Mac release does not update iPhone or iPad. No companion server update or restart is required.

Install through **Herdr Companion → Check for Updates…** with preview builds enabled.

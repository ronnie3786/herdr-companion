# macOS 0.14.0-beta.1

- Sending a Pi prompt no longer requests audible success feedback. Starting activity stays silent; completion and attention alerts are unchanged.
- Right-click a color shortcut in the left sidebar and choose **New chat**. If several tabs share the color, choose the destination tab. The new chat inherits its tab’s color.
- Color-shortcut titles wrap naturally to at most two lines without reserving a second line for short labels.
- New HUD chats start in the selected machine’s home folder (`~`). Use the HUD folder menu to choose, add, or remove custom paths saved separately for each machine on this Mac. Existing chats retain their original working folder.

## Compatibility

Mac-only update. Uses the existing HUD chat and pane-creation APIs; no companion server update or restart is required. Custom folder paths refer to the selected companion machine, not necessarily this Mac, and must exist on that machine. Saved folder choices are local Mac preferences and do not sync to other clients.

Install through **Herdr Companion → Check for Updates…** with preview builds enabled.

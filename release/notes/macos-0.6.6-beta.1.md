# Herdr for Mac 0.6.6 beta 1

- Recents now bolds the project/workspace name and increases the secondary line by 1 point.
- HUD agent bubbles are about 20% wider, with room for agent names to wrap to two lines. Row height and scrolling budgets grow with the text-size setting.
- Fixed modified Return in prompt inputs. Shift-, Command-, and Option-Return now insert a newline at the selection before SwiftUI can route the event as a submit action. The HUD shares the main chat's scrolling editor; ordinary Return still sends. Undo and redo keep the draft in sync.

## Try it

Open Recents from the sidebar clock menu to see the stronger workspace labels. Hover over the HUD and inspect a session with a long name. In either chat prompt, place the caret mid-sentence or select text, then press Shift-Return or Command-Return: a newline should appear there without sending. Check Undo and Redo, then use plain Return to send when ready.

## Compatibility

Mac-only update. No companion server, Pi extension, or iPhone update is required. This preview uses development signing and is not notarized.

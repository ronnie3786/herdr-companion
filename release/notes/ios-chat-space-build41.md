# iOS 0.1 (41)

## More room for chat

- Conversation rows now use the full reading width. The decorative turn rail,
  dots, and reserved gutter are gone while streaming, working groups, errors,
  stable row identity, and older-row windowing remain intact.
- The large pane card no longer repeats the title, agent, idle state, star, and
  location above chat. The complete title moves to a one-line inline navigation
  title with tail truncation and a full VoiceOver label.
- Model and Thinking remain independent 44-point controls, but each is now one
  quiet value line instead of an outlined two-line card. Narrow and accessibility
  layouts continue to stack safely with spoken-response controls.

## Clearer actions and navigation

- Star remains in Pane actions. **Chat history → Last prompt** moves there too,
  accurately exposing only the latest visible user prompt; it is disabled when
  no user prompt is available and keeps the copy sheet.
- Pushed panes from Agents, Attention, and Activity use native Back and swipe
  without a duplicate navigator button. Root and iPad split-detail panes show
  the app Chat navigator; split detail removes the automatic Agents-column toggle.

## Compatibility and delivery

No companion server, Mac app, Pi extension, authentication, or API contract
change is required. The app and widget project build number is 41; marketing
version remains 0.1. `release/ios.json` remains unchanged because it describes
the older 0.16.0 (39) delivery metadata and is not the build-41 source of truth.

Regression tests and native render/UI checks are included but are intentionally
not claimed as run in this note. Final validation, signing, private packaging,
and installation-link publication belong to the reviewed release gate.

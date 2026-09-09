# Herdr for Mac 0.6.3 beta 1

- Shrink the HUD Notes toggle to 32 points, matching the microphone button.
- Add 10 points of vertical room between Recents chats.
- Restore Shift-, Option-, and Command-Return newline insertion without overwriting the draft. Plain Return still sends.
- Re-anchor Terminal follow when its viewport changes, including after switching from Chat.
- Reduce Chat and HUD response text from 17 to 15 points, with proportionally smaller headings; reduce composer text by one point. Existing text-size preferences still apply.
- Show multiline Command previews and the full command on expansion. Expanded tools expose available structured input and partial output while running.
- Restore prominent green/red diff backgrounds for added/deleted lines, gutters, and changed text without replacing the lavender Git chrome.
- Prioritize full filenames in Git file rows, with a left-truncated directory hint and a full-path hover tooltip. Exceptionally long filenames wrap instead of truncating.

## Try it

Open Recents, toggle HUD Notes, and insert newlines in a draft with Shift-Return and Command-Return. Switch between Chat and Terminal with follow enabled and resize the window. Expand a running Command card to inspect its input and available output. In Git, compare a changed file side by side and hover a file row to see its path.

## Compatibility

Mac-only update; no companion server or iPhone update is required. Browser filename styling is also updated in source and takes effect when those web assets are deployed. This preview uses development signing and is not notarized; signed update verification remains enabled.

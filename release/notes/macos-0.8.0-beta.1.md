# Herdr Companion 0.8.0-beta.1

## Quotes for the latest response

- Quote & comment is now available only on the latest completed agent response, including its code blocks. User prompts, older replies, tools, thinking, and previous-session chapters stay copyable but do not offer quoting.
- The popup anchors beside the visible selection endpoint, including multiline or partially scrolled selections.
- Save keeps a removable, previewable quote chip. Sending puts the actual excerpts and comments into the prompt under **Quoted response segments:**, with **User’s message:** after each excerpt. No new `Quoted_chat.md` files or attachment paths are created. Quote-only messages work too; ordinary file attachments are unchanged.

## New Pi chat, with visible history

- The main chat's **Pane actions → New Pi chat** captures the outgoing transcript before reset, shows progress, and confirms the new session by polling as well as the live stream.
- Fixed the visibility bug that hid the previous chapter and divider while the new session was empty.
- The timeline moves to a quiet **New conversation** boundary with the full, copyable **Previous session** ID and the new ID. Earlier messages remain above it and stay outside the new agent's context.
- **Compact Chat** and **Reload Pi extensions** now live in **… More** in the prompt composer. Existing connection and compaction safeguards remain enabled.

## HUD and Notes

- Bubble titles use their natural one- or two-line height. Panel and scroll budgets follow the measured content rather than reserving a blank second title line.
- The model name and cumulative cost fade between each other every five seconds beside the state label. Missing metadata is not fabricated; Reduce Motion disables the fade.
- HUD Notes title/body defaults are another point larger. Removed New note from the note-card header; create notes from the stack or File menu.

## Paste code

Paste code now appends a fenced clipboard block to the end of the draft, without replacing the current selection. **Command-Shift-V** invokes the same action while the Chat or HUD prompt editor is focused. Clipboard whitespace and embedded fences are preserved safely. Other fields retain their normal shortcut behavior.

## Verify and update

Enable preview builds, then choose **Herdr Companion → Check for Updates…**. Try quoting only the newest reply; send two quote chips and inspect the inline prompt. Start a new Pi chat and check the previous messages and closed session ID. In a prompt, move the caret to the beginning and press Command-Shift-V: the fenced snippet should still appear at the end. Hover a running HUD bubble long enough to see model and cost alternate.

Synthetic proof screenshots are in the repository at `docs/screenshots/macos-0.8.0/`. The full new-session render is checked with local text recognition for its divider, previous-session label, and retained messages. Regression tests also cover quote eligibility, popup geometry, inline submission, focus-scoped shortcuts, and natural bubble heights.

Mac-only update; no server, Pi-extension, or iOS update is required. Existing chat archives, notes, connections, bundle identity, and signed update feed are retained. Experimental preview signed for personal testing, not notarized; signed update verification remains enabled.

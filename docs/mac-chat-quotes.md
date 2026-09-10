# Mac chat quotes and session chapters

## Quote the latest response

**Quote & comment…** is available only on text or code from the latest completed
agent response in the current Chat or HUD conversation. User messages, earlier
agent replies, thinking, tools, and previous-session chapters remain readable and
copyable but do not offer quoting. A new in-progress response supersedes the old
quote target. An open quote action is removed when its response is no longer
eligible.

Select text to reveal a small action beside the visible selection endpoint, or
choose the same action in the selection's context menu. Multiline selections anchor
near the selected line at the end of the drag, rather than an offscreen first line.
The editor repeats the exact excerpt above the comment field. **Save** stages a
previewable quote chip; it does not send, create a file, upload an attachment, or
create a standalone Notes card. A nonempty comment is required. **Cancel** discards
the unsaved comment.

Hover a saved chip to preview its text and comment, or use **Preview quote** in its
context menu. Remove it with X. When sending, both Mac composers put the segments
directly into the prompt, after any ordinary draft text:

```text
Quoted response segments:

> First selected excerpt
> Another line of the same excerpt

User’s message: Comment about that excerpt.

> Second selected excerpt

User’s message: Comment about this one.
```

Sources remain visible in previews, but no `Quoted_chat.md` file paths are sent.
Normal file attachments still use their existing upload flow and limits. Quote-only
prompts are supported. Failed HUD submissions restore the draft and quote chips
without duplicating the quoted text. Existing file-based quotes from older releases
remain readable in saved HUD history.

Unsent quote chips use the existing pane-composer lifecycle: switching Chat/Terminal
on the same pane retains them; leaving that pane discards them. Sent quotes are plain
text in the saved conversation. This is not a cross-device annotation system and
does not add persistent marks to the original response.

## Session chapters

The main window's **Pane actions → New Pi chat** captures the outgoing transcript
before dispatching `/new`. Progress is visible immediately. The app confirms the new
session ID by snapshot polling as well as the live stream, so it does not depend on
an SSE reset notification. An early empty checkpoint cannot erase the captured
history. Failures are shown without inventing a new session or a closed chapter.
If confirmation is delayed, check Terminal; the composer unlocks when confirmed.

The previous chat stays above a quiet **New conversation** divider. The full,
selectable and copyable **Previous session** ID is beside the divider, with the new
ID underneath. The timeline scrolls to this boundary, and remains visible even
when the new session has no messages. Older chapters can be expanded and messages
are mounted in bounded batches. Closed chapters contain read-only messages,
thinking, tool details, and notices; historical controls cannot execute.

Archives are local, scoped to machine and pane, and survive relaunch. They are not
automatically included in the new agent's context. They preserve only the transcript
available while the Mac was following it, not context Pi already omitted or sessions
that changed while the app was away. Unreadable archives are preserved and save
failures are shown without hiding the in-memory history.

**Compact Chat** and **Reload Pi extensions** now live in the prompt's **… More**
popover. New Pi chat remains in Pane actions. Existing connection, submission, and
compaction guards stay in effect.

## Paste code

**Paste code** appends clipboard text to the end of the draft in a fenced code
block, regardless of the caret or selection. **Command-Shift-V** invokes the same
action only while a Chat or HUD prompt editor is focused; other text fields keep
their normal shortcut behavior. Clipboard whitespace is preserved. Ordinary content
uses triple backticks; content containing backticks gets a longer enclosing fence
so the snippet remains intact. Pasting does not send or execute the content.

## Verification and compatibility

No server, iOS, or Pi protocol update is required. Quotes use the ordinary text
prompt contract. Native text measurement stays isolated from the displayed TextKit
stack, preserving the 0.7.1 overlap fix across resizing and streaming.

Tests cover latest-response eligibility, visible glyph anchoring, inline prompt
serialization and quote-only HUD submission, focused keyboard routing, append-only
code paste, new-session confirmation without SSE, early empty checkpoints, failures,
timeouts and late confirmation. The full new-session render is checked with local
text recognition for the divider, previous-session label, and preserved message
content—not just the existence or size of a screenshot.

The [new-session screenshot](screenshots/macos-0.8.0/new-pi-chat.png) uses entirely
synthetic data and the production command/store/view path with a simulated companion.

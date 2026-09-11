# Pane links in Mac agent replies

Agent replies in Chat, saved HUD conversations, and the Agent window recognize
pane references as in-app links. Click a linked reference to open the target
pane. HUD links collapse the floating chat and open the main Companion window.
Existing navigation history and pane selection behavior are retained.

Examples, assuming those panes exist on connected machines:

- `w3:p9` — the pane on the machine that produced this response.
- `desktop|w3:p9` — an explicitly machine-scoped reference.
- `herdr://pane/w3:p9` or `herdr://pane?pane_id=w3%3Ap9`.
- `herdr://pane/laptop%7Cw3%3Ap9` — an explicitly scoped deep link.
- `https://desktop.example.invalid/open/pane/w3:p9` — a universal link whose
  origin matches that machine's saved server URL, including its port.
- `[Open chat](herdr://pane/w3:p9)` — an existing Markdown link keeps its label.

## Validation and safety

Links are generated from the latest connected fleet snapshot, without making
network requests for each streamed token. A bare ID never silently switches to
another machine just because the same ID exists there. When the response has no
machine context, an unscoped ID is linked only if exactly one known pane matches.
Unknown IDs, ambiguous targets, conflicting URL parameters, and invalid pane-link
destinations are not made clickable. Unknown web origins are not treated as
in-app destinations, and ordinary external Markdown links keep their behavior.

Generated links include the target terminal identity. Clicks recheck the latest
known model before navigating; a closed, moved, replaced, or disconnected target
gets an unavailable message instead of an operating-system/browser fallback.
This is snapshot validation, not an atomic server-side guarantee: a native pane
can still change before its next update reaches Companion.

Recognition happens after Markdown parsing and styling, outside the text cache.
Prose and inline-code references can be linked, including within headings,
lists, and tables. Copying and quoting preserve the original response text.
User prompts, thinking/tool details, and fenced code blocks are not automatically
linked. Both native selectable/quotable text and ordinary SwiftUI text dispatch
links through the same in-app handler.

This is a Mac-only presentation change using the existing API. No Companion
server or Pi-extension update is required for response links. The separately
added **End Pi & close pane** preservation feature does require its updated server;
see [keeping tabs open](keeping-tabs-open.md).

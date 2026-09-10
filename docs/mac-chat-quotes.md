# Mac chat quotes and session chapters

## Interaction design

Selecting text should still behave like a Mac: native drag selection, keyboard
selection, and Copy. In Chat and the HUD, a small **Quote & comment…** action
appears beside the selection. The selection's context menu offers the same action.
It opens a compact editor with the exact selected text highlighted in the original
message and repeated above the comment field.

**Save** stages a quoted Markdown attachment in the current composer. It does not
send a prompt, launch an agent, or create a standalone Notes card. A nonempty
comment is required. **Cancel** discards the unsaved comment. The editor stays open
if saving fails. Selecting text again never replaces an already saved attachment.

Attachment chips use a quotation icon and the comment as their label. Hover briefly
for the excerpt, comment, and source-session preview; **Preview quote** in the
context menu also works without hover. Remove an attachment with its X. Quotes
obey the existing attachment count and size limits. The main chat uploads the
Markdown through the existing authenticated attachment API; the HUD retains its
copy for history and retries. An agent receives it only when the user sends.
HUD sent-attachment previews survive relaunch. Main-chat sent attachments retain
the existing transcript attachment-path presentation.

Quote capture includes the visible selected text, not hidden Markdown syntax,
with its session/exchange identity and, in the main timeline, message identity.
Multiline excerpts and Unicode are preserved. Copy and code-block Copy remain
independent of quote creation. Pending main-window attachments retain the existing
composer lifecycle: switching panes discards them. This feature does not add
cross-device quote annotations or persistent marks on the original messages.

## Session chapters

A confirmed Pi session identity change closes the previous conversation into a
read-only local chapter. It stays above the current conversation in the same
scroll view. The latest previous chapter opens automatically; older chapters can
be expanded. Messages are mounted in bounded batches, with **Show earlier
messages** for the rest. Each chapter shows the full, selectable and copyable
closed session ID and the time the Mac observed its closure.

Chapter contents include the transcript available on this Mac: user messages,
responses, and read-only thinking/tool/notice details. Historical permission and
tool controls cannot execute. The divider makes clear that readable local history
is not automatically included in the active agent's context. Quotes can explicitly
bring an excerpt into the new conversation.

Reconnects, compaction, and unsuccessful `/new` commands do not create chapters.
Confirmed identity changes made from the terminal are handled too. Local archives
are scoped to the machine and pane and survive relaunch. Existing Pi truncation is
reported; the app cannot restore content the server had already omitted or chats
that changed while the Mac was not following them. Unreadable archives are kept
rather than overwritten, and save failures are shown without hiding the in-memory
chapter.

## Compatibility and verification

No server, iOS, or Pi protocol update is required. Markdown file attachments use
the existing contract. Notes keep their existing persistence and sync format.
The name **Herdr Companion** changes presentation and the release bundle filename,
not bundle ID, URL schemes, preferences, credentials, or the signed update feed.
Sparkle may retain an existing installation's bundle filename during an update.

Regression coverage includes native selection/layout, Unicode excerpts, quote
attachment round trips, legacy HUD records, Save-without-send, native note cursor
color, confirmed session boundaries, reconnect deduplication, per-pane isolation,
archive restoration and corrupt-file preservation. Synthetic render tests cover
the HUD, notes, quote editor/preview, and archived session chapter.

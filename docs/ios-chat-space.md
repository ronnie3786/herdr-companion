# iOS chat-space and attachment follow-up

This follow-up to `77a9c8a` replaces the separate pane-mode row from the original
[mobile implementation plan](ios-mobile-v2-implementation.md).

## More room for the conversation

- **Pane actions → View** contains Chat, Git, Terminal, and Skills, with a
  checkmark for the current mode. The segment bar is removed. Chat still
  requires semantic Pi support; Git still waits for a confirmed repository.
- Conversation rows are flat and use the complete reading width. The decorative
  turn rail, dots, and reserved leading gutter are removed without changing lazy
  row identity, working groups, streaming updates, errors, or transcript windowing.
- Model and Thinking retain separate semantic actions, live capability/catalog
  state, full VoiceOver labels, and 44-point touch targets. They are small plain-text
  pickers grouped at the leading edge, with a down chevron immediately after each
  interactive value. Read-only values omit the chevron. Listen and TL;DR remain
  independent 44-point actions at the trailing edge but render only speaker and
  quote icons; preparing, playing, and paused states use spinner, pause, and play
  indicators without visible action words. Common values share one 44-point row at
  320–430 point widths; a long model truncates within the available leading budget,
  while accessibility text sizes stack instead of overlapping or wrapping values.
  Hidden audio reserves no space and does not separate Thinking from Model.
- The large in-content pane header is removed. A tail-truncated one-line inline
  navigation title retains the full accessible title. Agent name, idle status,
  standalone star, and machine/workspace/tab breadcrumb no longer consume chat
  space; active compaction and connection errors remain in the chat/composer.
- Star stays under **Pane actions → Chat organization**. The former toolbar clock
  is now the honest **Chat history → Last prompt** submenu action. Its sheet is
  owned by the pane view hierarchy, keeps copy/dismiss behavior, and is disabled
  when the transcript has no user message. It does not claim durable history.
- Navigation owners pass explicit pane context. Agents and Attention pushes,
  including Activity → pane, keep native Back and swipe with no navigator button.
  Root and regular split-detail panes expose the app's Chat navigator. Split detail
  removes SwiftUI's automatic Agents-column toggle so only that app navigator is
  shown; opening it presents the same Chat navigator drawer as compact layouts.
- The composer uses one quiet card: a full-width, system-font editor followed by
  Attach, Voice, More, and Send. Voice recording and hold-to-dictate remain
  available. Empty input keeps Send disabled rather than turning it into a
  second dictation entry point; explicit locked dictation is available in More.
- Terminal keys are absent by default. Choose **More → Show terminal keys** to
  reveal them, then **Hide terminal keys** to recover the space. Opening other
  tools does not reveal keys. More also contains workspace-file/Jira context
  and user-initiated Paste code.

## Visible attachments before Send

The attachment strip now sits inside the input card, with a bounded,
Dynamic-Type-aware height rather than an unconstrained horizontal scroller.
Each chip fits the available width and exposes filename, upload state, removal,
and retry after failure. Full text remains available to accessibility when the
compact visible label is truncated. A Preparing photo(s) indicator appears
while Photo Library transfers are pending, and Send waits for preparation and
upload. Leaving the composer or making a newer selection cancels obsolete
imports; their completions cannot insert files or clear newer progress.

Photo previews are downsampled before upload-source cleanup to at most 96 pixels
per dimension and 64 KB encoded. Only those small bytes are retained in the
non-Codable `TerminalAttachment` presentation value. Previews therefore survive
mode switches with the attachment metadata without retaining the full image or
fetching it again. Upload limits, security-scoped access, temporary-file
ownership, retry behavior, and origin-pane submission cleanup remain enforced.
These are in-memory composer attachments, not persisted attachment drafts.

No server, Mac app, Pi bridge, authentication, or wire-contract changes are
required. The build 43 picker-chevron and trailing icon presentation is iOS-only.
The earlier local-color and unsent-text draft behavior remains intact.

## Verification

Build 43 extends the deterministic 320/375/402/430-point and
Default/Accessibility 3 matrix for adjacent leading pickers, interactive-only
chevrons, trailing icon glyphs, hidden audio, loading, setting, disabled, catalog
error, empty catalog, read-only, preparing, playing, and paused states. It checks
44-point targets, non-overlap, accessible action labels, real glyph geometry, a
two-point options-to-editor gap, a synthetic full-composer capture, and independent
server-free UI interaction with both menus. Build 42 introduced the underlying
plain-control matrix. Existing coverage continues to check rail-free
row geometry, one-line title geometry, removed header/status/breadcrumb chrome,
Pane actions ownership of star and Last prompt, nonnil prompt
presentation/copy/dismiss,
composed synthetic conversation imagery, and navigation policy plus Agents,
Attention, Activity, and iPad split-detail routes. Those tests are authored but
intentionally not run until the final reviewed-candidate gate. The gate must also run the existing
attachment layouts, navigator/notes regressions, native unit suite, focused UI
suite, public-source guard, and signed device archive/package checks.

The earlier attachment follow-up was verified with Xcode 26.2, 349 unit tests,
10 UI tests, and its native render matrix. That older evidence is not evidence
for builds 42 or 43. A physical-device connected-Pi smoke test remains necessary
after installation; automated checks do not certify the complete iPad, VoiceOver, or
media-service matrix. Private captures, configuration, signing identities,
archives, and installation destinations stay outside source.

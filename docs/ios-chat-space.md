# iOS chat-space and attachment follow-up

This follow-up to `77a9c8a` replaces the separate pane-mode row from the original
[mobile implementation plan](ios-mobile-v2-implementation.md).

## More room for the conversation

- **Pane actions → View** contains Chat, Git, Terminal, and Skills, with a
  checkmark for the current mode. The segment bar is removed. Chat still
  requires semantic Pi support; Git still waits for a confirmed repository.
- Model and Thinking retain separate actions and live capability/catalog state.
  Their compact values no longer compete with a higher-priority expanding
  model control. Hidden audio controls reserve no space. Visible audio can move
  below the pickers; accessibility text sizes stack controls rather than
  squeezing or hyphenating their values. Touch targets remain at least 44 points.
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
required. The earlier local-color and unsent-text draft behavior remains intact.

## Verification

- Xcode 26.2 simulator build and signed device archive/export succeeded.
- **349 unit tests and 10 UI tests passed**, with no skipped tests. UI coverage
  includes menu-only modes, selected-mode accessibility labels, hidden/optional
  keys, draft continuity, file/Jira/voice access, and the existing navigator and
  notes regressions.
- Native UIKit renders cover 56 complete picker-bar combinations and eight full
  attachment-composer layouts at 320/375/402/430 points and default/Accessibility
  3 text sizes. They include nonnil hidden/visible audio, short/long/unknown/model
  loading states, and ready/uploading/failed attachments. Layout-neutral DEBUG
  anchors measure actual control and value bounds; release builds omit those
  probes. These are geometry checks, not a manual VoiceOver certification.
- A synthetic image was selected through the native Photos picker in demo mode.
  Its thumbnail and Ready state appeared inside the input, survived mode
  switches, and disappeared when removed; empty-input Send was disabled again.
  The demo upload did not contact a backend.
- The public-source guard and whitespace checks passed. Private user captures,
  configuration, signing identities, archives, and installation destinations
  remain outside source.

A physical-device connected-Pi smoke test remains necessary after installation;
these checks do not certify the complete iPad, VoiceOver, or media-service matrix.

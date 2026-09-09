# Comfortable reading on Mac

The Mac interface combines the Comfortable reading palette and prose with the
compact controls and navigation from Quiet chrome.

## Implementation passes

1. **Shared foundation:** charcoal and lavender palette, readable secondary text,
   restrained dividers, system typography, and consistent cards and input wells.
   Menu bar and embedded web surfaces use the same palette.
2. **Conversation and composer:** a bounded reading width, larger prose and more
   space between blocks, quieter activity cards, and a unified prompt input with
   labeled Attach, Paste code, and Voice actions. More contains the remaining
   context tools. Terminal keys sit above the input and expand on demand. Model,
   effort, voice, playback, draft, and keyboard behavior remain available.
3. **Remaining native surfaces:** sidebar, workspace and fleet summaries,
   attention, activity, settings, onboarding, command palette, Ask Herdr, HUD,
   quick voice, notes, and Active Work.
4. **Verification and delivery:** inspect synthetic renders at standard and large
   text sizes, run Mac tests and public-source checks, then publish through the
   verified Mac release workflow.

## Design contract

`HerdrTheme` owns native color and spacing tokens. Sidebar and detail backgrounds
are distinct, and text uses opaque readable foreground colors. Lavender denotes
actions and selection; mint, amber, and rose continue to communicate status.
Native filled controls use a deeper lavender because macOS retains white labels.
Code and terminal content retain monospace typography and semantic colors.

`HerdrProse` owns conversation typography and follows the user's app font scale.
The transcript has a 980-point maximum measure. Content can scroll horizontally
where code or tables need more space. The composer keeps its editor identity and
session-owned draft through changes in its utility controls.

Quiet chrome removes the transcript's decorative turn rails and dots, including
their reserved left gutter. The sidebar uses compact outline icons and one row
for creating sessions and workspaces. Only machine groups receive separators;
projects are distinguished by indentation, labels, and spacing. The toolbar uses
a compact segment strip with a restrained selected state.

Recents uses regular-weight chat titles aligned to the leading edge. A single
small, muted subtitle shows the computer icon, machine, workspace, and tab.
Long titles wrap to two lines; full context and last activity remain available
in hover text and accessibility labels. The subtitle follows the app text scale.

Streaming prose must not reserve empty rows or boundary blank lines that disappear
when the response finishes. Whitespace inside code fences remains intact. The
composer and navigation continue to adapt to the app's text-size preference.

Embedded Git and Active Work content receives presentation-only CSS from the Mac
host. Bootstrap authentication, navigation restrictions, native message handling,
and the shared server/web/iOS API contract are unchanged.

## Regression checks

- Sending, modified Return/newlines, code paste, draft restoration, attachments,
  skills, file search, Jira, model and effort selection, abort, and compaction.
- Dictation press and hold, recording lock, transcription, and audio playback.
- Long and streaming transcripts, including short updates between activity groups,
  collapsed activity, failures, tables, and code.
- Sidebar selection, unread and starred sessions, keyboard navigation, large text,
  and narrow windows.
- Settings validation, machine configuration, and embedded Git/board navigation.

Only synthetic fixtures may be used in repository screenshots and tests.

# Comfortable reading on Mac

The Mac interface uses the Comfortable reading design throughout its existing
sidebar, session header, transcript, and anchored composer layout.

## Implementation passes

1. **Shared foundation:** charcoal and lavender palette, readable secondary text,
   restrained dividers, system typography, and consistent cards and input wells.
   Menu bar and embedded web surfaces use the same palette.
2. **Conversation and composer:** a bounded reading width, larger prose and more
   space between blocks, quieter activity cards, and a unified prompt input with
   attachment and More controls. Terminal keys are available on demand. Model,
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

Embedded Git and Active Work content receives presentation-only CSS from the Mac
host. Bootstrap authentication, navigation restrictions, native message handling,
and the shared server/web/iOS API contract are unchanged.

## Regression checks

- Sending, modified Return/newlines, code paste, draft restoration, attachments,
  skills, file search, Jira, model and effort selection, abort, and compaction.
- Dictation press and hold, recording lock, transcription, and audio playback.
- Long and streaming transcripts, collapsed activity, failures, tables, and code.
- Sidebar selection, unread and starred sessions, keyboard navigation, large text,
  and narrow windows.
- Settings validation, machine configuration, and embedded Git/board navigation.

Only synthetic fixtures may be used in repository screenshots and tests.

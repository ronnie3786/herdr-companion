# iOS 0.17.0 (44)

- First Mates now opens a conversation list across your configured machines, with
  needs-you pins, search, readable status, unread dots and exact-owner navigation.
- Feature chat keeps complete messages, suggested replies, documents and saved
  sessions together. Sending clears a ready draft immediately; failed delivery
  keeps explicit Retry and Copy actions without overwriting a newer draft.
- My First Mate opens a real lead conversation on supported companions, with
  Automatic or pinned machine choice and a named offline stand-in. Older companions
  retain the explicitly client-built briefing and feature readouts.
- Photos, Files, fenced-code paste, hold-to-talk, same-machine mentions, safe model
  and thinking changes, coordinator context and response feedback stay with the
  original feature and machine. Capability checks and model-change confirmation remain.
- Info has Overview, Agents, Documents and Workflow underline tabs, saved-resource
  sheets and a persistent sync footer. iPad keeps the list, chat and Info in three
  columns while retaining the selected conversation and draft through rotation.
- Cached dusk backgrounds and capped Dynamic Type now apply throughout the app.
  Complete messages remain scrollable; Glass/Haze preferences and passive system
  accessibility fallbacks remain. Widget colors are unchanged.

This build reconciles the app, widget and iOS manifest at version 0.17.0, build 44.
The existing companion API remains compatible. Advanced lead, attachments, feedback,
context and safe model changes require their advertised capabilities; older hosts
keep explicit upgrade guidance. This iOS delivery does not update the companion,
Mac app or Pi extension. App badges, background refresh and push are deferred.

Synthetic native renders, ownership/concurrency tests and iPhone/iPad interaction
checks accompany the change. Exact-source Verify and independent review are required
before one signed build is published through Mobile App Hub. Physical microphone,
Photos and two-companion peer acceptance remain checks for that installed build.

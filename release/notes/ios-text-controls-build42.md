# iOS 0.1 (42)

## Smaller chat controls

- Model, Thinking, Listen, and TL;DR are now small plain-text controls without
  decorative icons, chevrons, capsules, borders, or persistent spinners.
- The controls keep independent 44-point tap targets, complete VoiceOver labels,
  live capability and disabled behavior, and the existing picker and audio actions.
  Active audio text changes to Stop, Pause, or Resume as playback changes.
- Common model and thinking values fit with both audio actions in one compact row
  across supported iPhone widths. Long and accessibility text still stack safely.
- The options row has less empty space above it and a two-point gap before the
  editor, leaving more room for the transcript without collapsing status,
  attachment, terminal-key, or input-card spacing.

## Compatibility and delivery

No companion server, Mac app, Car mode, Pi extension, authentication, navigation,
or API contract change is required. The app and widget project build number is 42;
marketing version remains 0.1. The unrelated legacy `release/ios.json` is unchanged.

Deterministic geometry and state coverage is included but intentionally not claimed
as run in this note. Final validation, visual capture, signing, private packaging,
and publication belong to the reviewed release gate.

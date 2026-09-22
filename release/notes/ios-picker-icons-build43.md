# iOS 0.1 (43)

## Clear picker and audio affordances

- Model and Thinking remain quiet plain-text controls but now show a small down
  chevron immediately beside each interactive value. The two pickers stay grouped
  at the leading edge, including when response audio is unavailable; long model
  names truncate within the available budget instead of separating Thinking.
- Listen and TL;DR return to icon-only controls at the trailing edge. Speaker and
  quote icons represent the idle actions, while preparing, playing, and paused
  playback use spinner, pause, and play indicators without visible action words.
- All controls preserve independent 44-point targets, complete VoiceOver actions,
  live capability and disabled behavior, and the existing model, thinking, and
  response-audio callbacks. Read-only values do not show picker chevrons.

## Compatibility and delivery

No companion server, Mac app, Pi extension, authentication, navigation, or API
contract update is required. The app and widget project build number is 43;
marketing version remains 0.1. The unrelated legacy `release/ios.json` remains
unchanged.

Deterministic render and server-free picker interaction regressions are included
but intentionally not claimed as run in this note. Final validation, visual
capture, signing, private packaging, and publication belong to the reviewed
release gate.

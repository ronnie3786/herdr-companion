# macOS 0.63.1-beta.1

Fixes long lines extending past the visible code area when **Wrap** is enabled in PR Review. Unified and split comparisons now wrap to the window width, including the plain-text fallback. Turning Wrap off retains horizontal scrolling.

Includes the shared Git comparison, commit-aware AI questions, workflow history, and guided-review improvements from 0.63.0-beta.1.

## Companion compatibility

Companion **0.62.0b1** or newer enables the shared comparison and AI features. Companion **0.62.1b1** also corrects Wrap in the web viewer's plain-text fallback. The Mac updater updates only the app; install companion packages separately.

## Install and verify

Use **Settings → Updates → Check for Updates…** with preview builds enabled. In PR Review, choose Split and turn Wrap on, then narrow the window: long lines should remain readable in each column. Turn Wrap off to scroll long lines horizontally.

This preview retains the existing Apple Development signature and signed update feed. It is not notarized.

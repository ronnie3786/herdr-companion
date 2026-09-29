# Herdr Companion 0.67.0-beta.1

One combined First Mate update for #70, #101, #102, and #103.

- **A sidebar that fits.** Drag the divider in the standalone First Mate window to resize the conversation list. Titles wrap to two lines; a narrow list shows only avatars and status dots, and widening restores the labels. The chosen width is remembered.
- **An inspector that stays out of the layout.** Overview and the other right-side tabs slide over chat instead of shrinking the conversation or sidebar. Use the header toggle or Command-I; Escape closes the panel.
- **Readable goals and quieter documents.** Goals, journal summaries, progress, and recovery prose render Markdown. Shared links keep neutral styling. Session-handoff checkpoints disappear from document lists and counts but remain stored for context and recovery.
- **Response actions where you need them.** Thumbs up, thumbs down, and Copy stay inside completed First Mate response bubbles in the main and standalone windows. The “Rate this response” prompt is gone; saved ratings, unavailable states, and retry controls remain.

## Try it

Open **Window → First Mate** (Shift-Command-F), enabling **Settings → General → First Mate chat window (preview)** if needed. Resize the left divider, open and close Overview, and check a completed response. In the main First Mate screen, check a Markdown goal and the Documents tab.

## Compatibility

No companion server update or configuration change is required for this release. Feedback writes still require the existing `first-mate-feedback-v1` capability; unsupported or offline feedback remains disabled. Document filtering uses existing exact handoff provenance and never deletes a checkpoint.

This signed preview updates the Mac app only. Matching document-list changes are included in the iOS source but require a separately distributed iPhone/iPad build. Companion servers and Pi extensions are not installed or restarted by the Mac updater.

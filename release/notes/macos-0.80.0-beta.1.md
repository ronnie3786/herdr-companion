# macOS 0.80.0-beta.1

## Saved PR walkthroughs

PR walkthroughs now keep preparing after you leave the review, switch reviews, or
close the window, and they stay saved until you archive the review.

- When a walkthrough is ready, or if it fails, Herdr posts a notification. Choose
  it to open the review.
- **PR Review** in the navigator shows a badge with the number of reviews that have
  a new walkthrough, and each review's row says **Walkthrough ready**. Opening the
  review clears both.
- Reopening a review shows its newest walkthrough for the current revision. One
  that is still preparing shows its progress.
- Archiving a review deletes its walkthroughs and your saved place in them.

[PR #147](https://github.com/ronnie3786/herdr-companion/pull/147)

This release also includes the First Mate HUD placement from 0.79.0-beta.1.

## Companion compatibility

Saved walkthroughs, notifications, and the badge need companion **0.71.0b1**
(`pr-review-walkthroughs-v1`) on the PR review host. With an older companion,
walkthroughs work as before. The Mac updater does not install the companion.

## Install and verify

With preview updates enabled, use **Settings → Updates → Check for Updates…** and
install **0.80.0-beta.1** (build **127**). Open a prepared PR review, choose
**Start walkthrough** in **Files**, then go to another review. When the
notification arrives, check the **PR Review** badge and the review's row, then
open the review to see the walkthrough and the badge clear.

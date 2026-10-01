# Companion 0.71.0 beta 1

This package adds saved PR review walkthroughs for Herdr Companion 0.80.0 beta 1
and remains compatible with older native clients.

- Walkthroughs finish on the companion even when no Mac is watching, including
  after a restart. The PR review loop completes them and records the result.
- Adds `pr-review-walkthroughs-v1`: `GET /api/v1/pr-reviews/{reviewId}/walkthroughs`,
  `POST /api/v1/pr-reviews/{reviewId}/walkthroughs/{guideId}/seen`, and a
  `walkthrough` summary on every review (`state`, revision, `comparison_id`,
  `needs_attention`).
- Publishes `pr_review.walkthrough` once when a walkthrough finishes or fails, so
  the Mac can notify and badge PR Review.
- Archiving a review now deletes its walkthroughs, answers, context snapshots, and
  pinned walkthrough source, and cancels a walkthrough that is still preparing.
  Unarchiving does not restore them.

Install the wheel in a new versioned runtime on the PR review host, back up
private configuration and state, and update the companion service, enabled
background workers, and CLI wrappers. The review database gains one table on
first start; no migration step is needed. Preserve the separate terminal service
and running Pi sessions. Follow the server update procedure in
herdr_harness/README.md. See docs/pr-review-buddy.md.

# Companion 0.77.0 beta 1

Adds persistent local PR Review discussions with Human and Agent messages, replies, resolve/reopen actions, editing history, original code anchors, and retry-safe writes. Discussions survive new commits and server restarts. Nothing is posted to GitHub.

Use Mac **0.92.0-beta.1** or later for inline discussions and the review-wide Comments view. Agents on the review host can use `herdr-pr-review comments`, `comment`, `reply`, `resolve`, `reopen`, and `edit-comment`. Existing clients remain compatible; discussion storage is added alongside the existing review data.

Install this wheel in a new versioned Python 3.11+ runtime, update the matching installed CLIs and Pi package paths, preserve private configuration and state, and restart the affected companion services using the server update procedure in the README. Retain the previous runtime and service definitions for rollback. Mac updates do not install this package.

After updating, confirm `pr-review-comments-v1` in the authenticated PR Review capabilities. Open a prepared review in the Mac app, add a comment and reply, then verify the same thread with `herdr-pr-review comments REVIEW_ID`. Resolve and reopen it to check the retained activity history. See `herdr-pr-review --help` and the PR Review documentation for configuration and inline anchor arguments.

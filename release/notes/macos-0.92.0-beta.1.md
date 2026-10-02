# macOS 0.92.0-beta.1

Preview channel, build 142.

## PR Review discussions

Select code and choose **Add comment** to start a discussion beneath its exact diff lines. Use **Comments → Add PR comment** for a discussion about the whole pull request. Messages show **Human** or **Agent**, support replies, and can be resolved or reopened.

Discussions persist on the review host and are shared with its `herdr-pr-review` CLI. New commits keep open findings, their original code and activity history, with **Earlier revision** labels for older anchors. Comments never post to GitHub. Existing Mac-only comments remain available under **Previous Mac comments**.

## Companion compatibility

Install companion **0.77.0b1** separately on each review host to enable `pr-review-comments-v1`. Older companions show an upgrade notice. The Mac updater installs only the app; it does not install or restart the companion server.

## Install and verify

With preview builds enabled, choose **Settings → Updates → Check for Updates…** to install **0.92.0-beta.1** (build 142).

Open a prepared PR review, select code, add a comment, reply, then resolve and reopen the thread. Open **Comments** to inspect the original code and activity history. An agent on the review host can list and update those same discussions with `herdr-pr-review comments`, `comment`, `reply`, `resolve`, `reopen`, and `edit-comment`.

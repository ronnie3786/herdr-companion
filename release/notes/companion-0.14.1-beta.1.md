# Companion 0.14.1 Preview 1

The matching Pi bridge saves rate-bounded intermediate checkpoints during long active runs, reducing the event backlog needed to reopen or rebuild a chat. Final settled-session checkpoints and ordered semantic replay remain intact. The package includes the companion server, matching CLIs, web assets, and Pi extensions.

The semantic API remains version 1. Existing compatible Mac, iOS, and web clients continue to work. Install Mac **0.14.1-beta.1** separately for the reconnect and atomic chat-recovery improvements; a bridge update alone does not fix an older app's reconnect behavior.

## Installation is separate from the Mac updater

1. Download the wheel and verify it against this release's `SHA256SUMS`.
2. Follow [the server update procedure](https://github.com/ronnie3786/herdr-companion/blob/companion-v0.14.1-beta.1/herdr_harness/README.md#update-the-server): install into a new Python 3.11+ environment, preserve the existing private configuration and state, validate the packaged installation, take a consistent backup, then deliberately switch the service and matching CLI launchers. Keep the previous runtime for rollback.
3. Update only the matching Herdr Pi package entry to the new runtime's bundled extension, preserving other packages. New Pi sessions then use the new bridge. Idle sessions using the global package can use `/reload`. Sessions launched with an explicit `-e` or `--extension` path should be exited and resumed using the updated installation; `/reload` keeps the old launch-time path and can load both versions.

Publishing this package does not install it, change a service, or restart any remote machine. The Mac updater never installs companion wheels. iOS is distributed separately.

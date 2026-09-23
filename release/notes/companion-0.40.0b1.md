# Companion 0.40.0b1

Companion/server package for the PR Review improvements in macOS 0.40.0-beta.1. Retains Agent Profiles and First Mate stability/recovery from the preceding previews. Existing native and web API contracts remain compatible; PR Review needs no new configuration keys.

- Ask Herdr's PR Review system prompt defaults to the short version unless more detail is requested.
- Refresh handles new/rebased PR heads, coalesces overlapping requests and keeps the last usable review after an error.
- Revision metadata and file lists publish atomically; old ranking jobs cannot overwrite a new revision. Changed patches reset their local viewed mark; unchanged patches retain it.
- GitHub viewed-file sync failures no longer fail review preparation. Tracked edits in managed checkouts are preserved, with a retryable message instead of overwriting them.
- Impact ranking asks for a brief, plain-English reason with review guidance.
- Web assets share the Mac PR Review code renderer and roomier syntax-highlighted styling.

## Installation

Install on the PR review host using its existing private configuration and the [server update procedure](https://github.com/ronnie3786/herdr-companion/blob/main/herdr_harness/README.md#update-the-server). Back up state consistently, create a new versioned virtual environment, install the wheel, verify it, and deliberately switch the service only when ready. Retain the prior environment for rollback.

```sh
python3.11 -m venv /path/to/new-runtime
/path/to/new-runtime/bin/python -m pip install ./herdr_companion-0.40.0b1-py3-none-any.whl
/path/to/new-runtime/bin/herdr-server --help
```

The wheel includes web assets and the Pi package. Keep the configured authentication and state locations. This release does not remotely install anything or restart active services. The Mac Sparkle update does not install this package. Existing sessions retain their pinned Agent Profiles snapshots; follow the earlier profile adoption and First Mate recovery guidance before switching configuration.

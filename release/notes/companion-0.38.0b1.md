# Companion 0.38.0b1: Agent Profiles

Adds authenticated, revisioned SOUL.md and USER.md profiles, explicit single-owner sharing, cached offline preferences, per-machine additions, history restoration and reviewed agent proposals. Includes the `herdr-profiles` CLI and matching Pi extension.

Pair with the Mac Agent Profiles editor in **0.38.0-beta.1**. Existing native and browser clients remain API compatible. This package does not install or replace the Mac app.

## Installation and verification

Build/install the exact release wheel in a new Python 3.11+ versioned environment. Preserve private configuration, credentials and state. Run the matching `scripts/verify-installed.py`, validate configuration and Fleet paths, take consistent SQLite backups, then update the companion service, matching enabled workers, CLI wrappers and the single Herdr Pi package entry. Keep old runtimes and definitions for rollback. See `herdr_harness/README.md`.

Assign profiles deliberately in Mac Settings → Agent Profiles or Fleet → Agent Profiles. Owned Personal and Work templates begin empty and unassigned. Remote bindings fetch only their explicitly selected owner's current document; offline hosts retain the last accepted revision. Documents are limited to 16 KiB each and must never contain credentials.

New pane conversations, HUD chats and independent First Mate assignments resolve the execution host's profile. Existing pinned conversations and assignment retries keep their snapshot. Restricted question/rename/brief helpers do not load profiles. First Mate supervisors use the selected runtime even when a feature checkout contains an older same-named Python package.

New Pi sessions use the updated package automatically. Existing global-package sessions can use `/reload` while idle; explicit old extension overrides require a safe exit/resume without that override. Start a new conversation to adopt a changed profile. See `docs/agent-profiles.md` for API, privacy and retention limits.

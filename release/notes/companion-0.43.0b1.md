# Herdr Companion server 0.43.0b1

Provides the optional API data used by the Mac 0.43.0-beta.1 Dashboard and Agent view.

- First Mate list responses include bounded stage, latest-message, attention, and agent-count summaries without loading every full conversation.
- PR lists include actual skill-run summaries and cached review state for the authenticated GitHub viewer. A single background worker refreshes GitHub state; failures retain the last successful timestamp and explicit stale or unknown state.
- The authenticated review-status refresh endpoint refreshes metadata without rebuilding a PR checkout.
- Retains the previously released First Mate authorized-stage continuation and verified recovery behavior.

The API additions are optional and remain compatible with existing native and web clients. GitHub review status uses the server’s existing authenticated `gh` configuration; no credentials are bundled.

Install the wheel into a new Python 3.11+ versioned runtime. Preserve the private configuration and state, take consistent SQLite backups, and update the companion service, matching command wrappers, Pi extension, and enabled workers. Keep the prior runtime and service definitions for rollback. Follow `herdr_harness/README.md` under “Update the server.”

This package does not install or replace the Mac app. The Mac app is distributed separately through its signed update feed.

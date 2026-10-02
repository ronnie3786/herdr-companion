# Companion 0.73.0 beta 1

This package adds the shared skim service for main Mac Chat and optional suggested replies for Mac Chat, First Mate, and HUD conversations.

The new `skim-v4` prompt gives summaries about 20% more room for useful detail. It can return zero to three short reply options with one-sentence explanations. Optional next steps remain grounded in the original response. The authenticated `chat-skim-v1` API uses the existing configured skim model, a bounded worker pool, and a private persistent cache. It leaves full responses available when skimming is unavailable or fails.

Use Mac **0.81.0-beta.1** for the new main Chat skims and reply chips. Existing native clients remain compatible with the additive fields; iOS continues to show its existing skim presentation. There are no new required configuration keys. The Mac updater does not install this server package.

Build the web assets and install the exact wheel in a new versioned runtime. Validate the existing private configuration and Fleet paths, take a consistent state backup, and switch the companion service, matching CLI wrappers, Pi package, and enabled background workers. Preserve their existing settings and data. Follow [the server update procedure](https://github.com/ronnie3786/herdr-companion/blob/main/herdr_harness/README.md#update-the-server), then verify authenticated health and `GET /api/v1/skims/capabilities`. Keep the prior runtime and service definitions for rollback. Start new Pi sessions to load the updated installed extension.

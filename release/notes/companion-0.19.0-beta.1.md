# Companion 0.19.0 Preview 1

## Agent control discovery and relay

- Adds the `agent-control-v1` and `discovery-v1` capabilities: an authenticated discovery endpoint for cross-machine chat, workspace, and tab search with per-source continuation cursors and match evidence, plus a durable control relay with stable server identity, hashed receiver secrets, instance binding, expiry, queue/retention limits, and immutable idempotent outcomes.
- Installs the `herdr-control` JSON CLI next to the existing commands. It separates finding and managing data from controlling a receiving Mac UI client, with receipts, bounded wait, and dry-run support.
- Discovery reads live topology, saved HUD chats (with real excerpts), First Mate text and metadata, and verified Active Work ticket links. Raw snapshot data stays raw; enrichment happens on copied data. Closed standalone Pi archives and unverifiable legacy associations are explicitly not fully indexed.
- Existing endpoints and clients remain compatible. The Pi extension bundled with this package adds concise CLI-discovery guidance to Herdr agent sessions.

## Matching components and safe update

Use companion **0.19.0b1** with macOS **0.19.0-beta.1** for agent control. The signed Mac updater does not install this package, update its bundled CLIs or Pi extension, switch services, or restart a companion.

Follow the documented [server update procedure](https://github.com/ronnie3786/herdr-companion/blob/companion-v0.19.0-beta.1/herdr_harness/README.md#update-the-server): preserve the private configuration and rollback environment, take a SQLite-consistent backup, install the wheel in a new versioned runtime, verify it, and explicitly switch only the intended service. Publishing this package does not perform a rollout. No live provider-quality test is claimed.
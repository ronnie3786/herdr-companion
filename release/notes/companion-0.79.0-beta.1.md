# Herdr Companion Server 0.79.0 beta 1

- First Mate peer requests allow 60 seconds by default. A request timeout reports an unknown operation outcome and no longer marks a responsive machine offline or automatically repeats a write.
- Configure the peer request budget with `first_mate.peer_timeout_seconds` in private configuration (15 to 300 seconds). Native First Mate reads allow 90 seconds; larger server overrides do not change client budgets.
- Queue projections include pending coordinator directions, queued workers, and recorded follow-up stages independently of conversation pagination. Current workers take priority over completed history in coordinator status.
- Status responses compact repeated historical verification evidence while preserving current failures, durable evidence, and references to full detail. Scheduling and status reads avoid unnecessary telemetry scans.
- Native terminal and Pi acknowledgements allow 30 seconds. Control and First Mate CLIs allow 60 and 90 seconds respectively; explicit terminal completion waits retain additional transport headroom.

Install this wheel into a new versioned runtime, preserve private configuration and state, validate configuration and Fleet paths, take a consistent state backup, then update the companion service and matching CLI/Pi package paths. Retain the previous runtime and service definitions for rollback. Follow `herdr_harness/README.md` for verification.

Pair with Mac 0.94.0 beta 1 or the matching iOS build for the current/upcoming activity panels. Existing native clients and legacy detail APIs remain compatible. The Mac updater does not install this server package.

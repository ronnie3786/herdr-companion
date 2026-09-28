# Companion 0.64.0b1

New First Mate coordinator turns allow 24 hours without model output or completed tools, with a seven-day absolute maximum. Existing shorter values in the private configuration remain authoritative.

This is a separate companion package, compatible with current native and web clients. It does not install through the Mac app updater. Use the repository README's standalone installation procedure to install the wheel into the companion's environment and restart its service. Preserve the private configuration and state directory.

For explicit long-running settings, set `coordinator_timeout_seconds = 86400` and `coordinator_max_seconds = 604800` under `[first_mate]` in the operator's private TOML. Both accept 30 through 604800 seconds. Already dispatched jobs retain their persisted budgets; installing the package does not restart or resubmit them.

To roll back, reinstall the preceding wheel using the same private configuration and state directory. No database migration is added by this release.

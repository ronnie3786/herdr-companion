# Herdr Companion server 0.48.0b1

Matching companion and Pi package for the unified 0.48.0 release (PRs #64, #67, and #69).

- Adds authenticated `quick-session-launch-options-v1`: explicit model, thinking level, focus, and server-home folder handling for new Mac HUD workspace chats.
- Adds `first-mate-verification-v1`: durable suite inventories, revision-bound gate results, explicit gate selections, and conservative coverage assessments across restarts and worker handoffs. Current failures, missing suites, dirty source, and stale evidence cannot become fully verified.
- Board cache versions include live verification changes, so changing source invalidates an earlier green even without a new workflow event.
- Includes the matching web interface and First Mate Pi tools. Existing native clients remain compatible. iOS All Machines browsing uses the existing per-host API.

## Install separately

Use the server update procedure in `herdr_harness/README.md`. Build/install in a new Python 3.11+ runtime, preserve private configuration, take a consistent state backup, validate the package and configuration, then explicitly switch the companion and matching CLI/Pi integration. Database changes are additive; retain the prior runtime and a consistent backup for rollback. Do not replace a live database with an older backup after new user writes without a separate recovery plan.

The signed Mac updater installs only the app. Publishing this package performs no server cutover and no iOS installation.

## Verify

Confirm both new capabilities in the authenticated API, create a synthetic workspace chat with an explicit model, and record a full verification set for a disposable feature. Select fewer gates or advance HEAD and confirm the visible downgrade survives refresh and restart. Test an old native client against the new server before updating clients.

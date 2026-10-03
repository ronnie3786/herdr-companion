# Companion 0.84.0-beta.1

Removes the Active Work server feature: its board page and API, durable-store
implementation, workflow templates, Buzz sync, board review watcher, activity
summaries, remote activity forwarding, and Pi discovery extension. The installed
`herdr-active-work`, `herdr-active-work-sync`, and `herdr-pr-review-watch` commands
are removed. Protected requests to the retired endpoints return 404.

Chat's live activity labels, First Mate, My Work, Notes, and the separate PR Review
API and CLI continue to work. Old board credentials no longer authenticate any
request. Main API token validation and authentication remain enforced.

Install this package separately on each companion using the
[server update procedure](https://github.com/ronnie3786/herdr-companion/blob/main/herdr_harness/README.md#update-the-server).
Stop and remove operator-managed schedules for the retired sync/review commands,
update the matching Pi package registration, and reload or resume existing Pi
sessions against the new package. Keep the private configuration, state, and prior
runtime for rollback. Wait for companion-owned jobs to finish before restarting
a busy server.

Old `[active_work]`, `[remote_activity]`, and `[providers.activity]` settings are
ignored so existing configuration files still load. Existing private board data
and workflow files are retained without being opened or migrated.

Update Mac clients to **0.102.0-beta.1** to remove their Active Work UI. Older Mac
clients see an unavailable board after this server update; their other features
continue to work. The Mac updater does not install this package, and publication
does not restart a server.

To verify, authenticated requests to `/board/` and `/api/v1/active-work` return
404, `/api/v1` no longer advertises board endpoints, and a running Pi chat still
shows its current activity. See the
[full compatibility notes](https://github.com/ronnie3786/herdr-companion/blob/main/docs/active-work-removal.md).

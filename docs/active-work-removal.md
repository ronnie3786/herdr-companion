# Active Work removal

Active Work is retired from the Mac app and companion server. The Mac no longer
has its menu destination, shortcut, pop-out window, native board, embedded board,
or background board requests. Saved navigation history skips retired destinations.

The companion no longer serves `/board` or `/api/v1/active-work`, creates or opens
the board database, emits `active_work.updated`, runs board activity summaries,
or forwards remote board activity. Its workflow templates and Buzz ingestion
support are removed. Authenticated calls to the retired routes return 404.

The separate PR Review feature, My Work watchlist, First Mate, Notes, Chat, and
Chat's current activity labels continue to work. First Mate's optional external
`work_item_id` reference remains readable for client and stored-data compatibility;
it no longer joins to a board or grants access to one.

## Upgrade the components

Install the Mac update through **Herdr Companion → Check for Updates…**.
The updated Mac works with an older companion, but removing the server feature
requires installing the companion package separately on each host. Updating the
companion first leaves older Mac versions with an unavailable Active Work screen;
update those clients as well. Other existing API contracts remain available.

Use the [server update procedure](../herdr_harness/README.md#update-the-server)
for the separately published companion wheel and its bundled Pi package. Stop and
remove any operator-managed schedules for `herdr-active-work-sync` and
`herdr-pr-review-watch`: these commands and `herdr-active-work` are no longer
installed. The removed review watcher belonged to the old board; the current
`herdr-pr-review` command and PR Review agents remain available.

Replace the matching Pi package registration with the new runtime's bundled
package. Use `/reload` in existing sessions, or restart/resume sessions that were
launched with explicit paths to the old discovery extension. No global Pi
instructions are rewritten by the upgrade.

Old `[active_work]`, `[remote_activity]`, and `[providers.activity]` configuration
sections are accepted but ignored, including their former secret-file references.
They can be removed from the private configuration. Former manage/ingest tokens
no longer authenticate requests; protected APIs continue to require the main
companion bearer token. Keep that token and normal API authentication configured.

The update leaves existing private board databases, workflow files, and backups
untouched. It provides no data-deletion migration and does not copy board data
into another feature. A companion package publication does not restart or replace
any running server automatically.

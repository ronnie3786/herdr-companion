# Companion 0.83.0-beta.1

## Share Agent Roles

- Adds `agent-roles-share-v1`. `GET /api/v1/agent-roles/export?preview=1` lists
  exportable roles; `GET /api/v1/agent-roles/export?roleIds=…` returns a
  `herdr-agent-roles` v1 document with each role's stored skill copies. Untouched
  built-ins, Recovery Advisor, machine IDs, revisions, team IDs and paths are never
  exported, and a private key in a prompt or skill file blocks the export.
- `POST /api/v1/agent-roles/import` plans a file with `dryRun: true` and applies a
  reviewed plan atomically with `planDigest`, `expectedRevision`, `roleIds` and
  `replaceRoleIds`. Existing roles change only when listed in `replaceRoleIds`.
  Skills are matched by content; a skill ID this computer already uses for other
  files is installed under a derived ID, so existing copies never change. Teams
  are matched by name. A commit bumps the revision and publishes
  `agent_roles.changed` once; dry runs and no-op imports do neither.
- The import route accepts the same 16 MB body as role saves. Deeply nested
  JSON bodies now return 400 instead of a server error.
- Teams travel by name and use the saved teams in this release
  (`pr-review-teams-v1`). Older Mac apps are unaffected. Install and restart this
  package separately from the Mac app.

## Saved PR review teams

- Adds `pr-review-teams-v1`. Teams are saved with stable IDs (`saveTeam` and
  `deleteTeam` role actions, at most 64 teams), agents store `teamId`, and team
  names from earlier versions become teams on the first read. Older Mac clients
  that send only a team name are matched to a saved team or create one.

Install this companion package separately on each server; the Mac updater does
not install it. Existing Mac and iOS clients keep working. Preserve the private
configuration and state, wait for active companion-owned jobs to finish before
restarting a busy server, and keep the previous runtime for rollback.

To verify: `GET /api/v1/agent-roles` lists `agent-roles-share-v1` and
`pr-review-teams-v1` in `capabilities`, and
`GET /api/v1/agent-roles/export?preview=1` returns the roles on that computer.

# Companion 0.74.0 beta 1

This package adds First Mate Agent Roles: private revisioned role settings,
optional role prompts, when-to-use guidance, delegation controls, custom roles,
and strict per-role skill selections. The authenticated `agent-roles-v1` API lets
Mac **0.84.0-beta.1** copy selected local skill packages to the execution computer.

The matching Pi extension filters the advertised skill catalog. Strict roles
require Pi supporting the controls verified with **0.87.1**; unsupported versions
fail clearly instead of silently loading every skill. Existing unconfigured
built-in roles retain automatic discovery, custom roles start with no skills,
and Recovery Advisor stays restricted. Conversations and queued assignments pin
their role and copied package snapshots.

The API is additive and existing clients remain compatible. Role settings and
copied packages stay in the existing private state directory. No new required
configuration keys or credential changes are introduced.

Install the wheel in a new versioned Python 3.11+ environment, validate the
existing private configuration and Fleet paths, and take a consistent state
backup. Finish active First Mate work before switching the companion service.
Update matching CLI wrappers, enabled workers and the installed Pi package while
preserving unrelated settings. Follow the [server update procedure](https://github.com/ronnie3786/herdr-companion/blob/main/herdr_harness/README.md#update-the-server),
then verify authenticated health and `GET /api/v1/agent-roles`. Keep the previous
runtime and service definitions for rollback. Start new Pi sessions to load the
updated extension. The Mac signed updater does not install this server package.

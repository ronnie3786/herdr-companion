# Companion 0.82.0-beta.1

Lets a person turn Watchers on or off for this machine from the Mac app, with no configuration edit or restart. Mac 0.99.0-beta.1 uses it.

- `POST /api/v1/watchers/settings` takes `{request_id, enabled, confirmed_by: "user", changed_via?}`. It works while Watchers is off, returns the capabilities payload, and starts or stops the scheduler at once. Turning it off pauses scheduling, never signals detached runners, and deletes nothing.
- Capabilities add `settings: {enabled, source: config|app|default, changeable}`. Each change publishes `watchers.updated` with `settings`, and `GET /api/v1` lists `watchersSettings`.
- `HERDR_WATCHERS_ENABLED` set to `"1"` or `"0"` still wins and makes the setting read-only (409 `watchers_setting_locked`). Other values are ignored. Without it, the choice is saved in a private `watchers-settings.json` under the state root; `HERDR_HARNESS_WATCHERS_SETTINGS_PATH` overrides the location.
- `herdr-watchers enable --i-confirm` and `herdr-watchers disable --i-confirm` are person-only verbs, like `activate`. `doctor`, `machines` and the disabled error now explain how to turn Watchers on, and `machines` rows include `settings`. Agents hold the main token, so `confirmed_by: "user"` is an audit convention, not a security boundary.
- Machines that set `HERDR_WATCHERS_ENABLED=1` behave as before, and older Mac apps are unaffected.

Install the wheel in a new versioned runtime using the server update procedure in `herdr_harness/README.md`. Preserve private configuration and back up state before upgrading, and restart only after active work is safe. The Mac updater does not install this package or restart companions. To host watchers, run the companion under a restart-enabled supervisor.

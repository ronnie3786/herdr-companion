# Companion 0.75.0 preview

Adds the optional Watchers scheduler, authenticated API and `herdr-watchers` CLI. Each machine owns its timezone-aware schedules, revisioned scripts, detached runs, gate cursors, logs and Watcher inbox. The service supports restart recovery, overlap protection, retention and request receipts. It works without an open Mac app.

Agents can discover the schema, examples, assets and smart-chip syntax, create drafts, ask for clarification, and stage edits through the focused Watcher builder. Activation remains the person's review step. This version executes scripts, gates and inbox delivery; agent and external delivery steps are draft-only.

Cronboard import has a nonexecuting preview, all-or-nothing imports, and explicit cutover and rollback commands. Confirmed enabled jobs arrive resting; disabled jobs stay as drafts. Import never changes Cronboard itself. Review scripts before execution: a Watcher dry run still performs a script's external effects.

Install this wheel and its matching CLIs separately from the Mac app, following the normal backup, hash verification, versioned-runtime and service-upgrade procedure. Python 3.11 or newer is required. Configure `HERDR_WATCHERS_ENABLED=1` in the selected machine's private environment, use a supervisor that restarts the companion, and check `herdr-watchers doctor`. Existing APIs remain compatible and Watchers is disabled by default. Mac 0.88.0 beta 1 adds the native Watchers interface. The app updater does not deploy server packages or migrate jobs. See `docs/watchers.md` for setup and migration.

# Companion 0.41.0b1

Companion server, CLIs, web assets and bundled Pi extension for First Mate's authorized stage continuation and evidence-checked recovery. Compatible with existing Mac, iPhone and web clients; Preview 2 of the Mac app includes matching release guidance.

- The original human request can record up to eight ordered follow-up stage keys. A completed stage proceeds only to the next recorded key at the same plan revision. A new human message preempts background continuation; a human gate is never waived.
- Stopped-worker recovery on a background turn uses the backup, effect-ledger, verified-writer-stop, advisor and bounded successor paths. An inconclusive advisor with trustworthy effects may yield a fenced inspection successor rather than a token human request. That successor must read the exact predecessor session before acknowledging a safe next step or requesting human direction.
- Unfinished or failed external effects, unverified writers, corrupt backups, real decisions, intentional pauses and exhausted budgets remain blockers. Existing blocked legacy features do not automatically resume. An interrupted detached build without a trustworthy completion receipt still requires investigation.
- SQLite migration preserves existing visits, assignments, memberships and their originating human-message references while allowing a single recorded request to authorize several successive visits. Back up the complete state consistently before cutover. No new configuration keys or credential changes are required.

## Installation and rollback

Follow the [server update procedure](https://github.com/ronnie3786/herdr-companion/blob/main/herdr_harness/README.md#update-the-server) on each selected host. Build/install this exact wheel into a fresh versioned Python environment, keep the prior runtime/service definitions, retain the private TOML and state, validate configuration and the installed package, and switch only after a consistent SQLite/state backup. Update the matching installed CLIs and Pi package without replacing unrelated packages; verify authenticated health, saved First Mate state, terminal access and configured background workers. If a cutover fails, restore the prior runtime/launcher without copying an older database over newer user data. Finish or quiesce any actively writing First Mate assignment before switching; never kill a live worker merely to deploy.

```sh
python3.11 -m venv /path/to/new-runtime
/path/to/new-runtime/bin/python -m pip install ./herdr_companion-0.41.0b1-py3-none-any.whl
/path/to/new-runtime/bin/herdr-server --help
```

The signed Mac app update is separate and does not install this wheel.

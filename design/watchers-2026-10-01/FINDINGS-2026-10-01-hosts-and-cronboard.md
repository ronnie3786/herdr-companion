# Hosts, app independence, and the live Cronboard install

**Layer 3, 2026-10-01.** Read-only checks on the machine that actually runs Cronboard (the work Mac) and on how each roster machine keeps its companion alive. Layer 1's "nothing is live to migrate" (plan §11, research cronboard §0) described a different Mac and is **wrong for the machine that matters**. Job names, paths and hosts are left out on purpose; shapes and numbers are real.

Labels as in the plan: **confirmed**, *inferred*, **proposal**.

## 1. What Cronboard runs today (confirmed)

- Cronboard **1.2.3** CLI and runner, app running, **10 managed jobs**: 5 enabled, 5 disabled. No unmanaged crontab lines.
- **24,747 runs** in about five weeks; 441 failed; **2 rows stuck `running`** for weeks (the "killed runner" flaw); 26 MB of history and 7 MB of logs with no retention.
- **Every job is script-only from the scheduler's point of view.** Seven are one-line entries that call a script elsewhere on disk; three embed the script (the largest is an 18 KB, 441-line Python body). Three start a headless agent *inside* their script. None needs an agent step, a gate step or a Slack adapter from the scheduler: they post their own results.
- Each job sets `HOME` and `PATH` itself, working around cron's empty environment.
- Schedules: `*/5`, `*/10`, `*/30 7-18 * * *`, `0 * * * *`, `0 7-21 * * 1-5`, `0 1 * * *`, `0 6 * * *`, `0 16 * * 5`, all in one IANA timezone. Interpreters: bash and python.
- Durations over two weeks: the short pollers average 1–7 s; hourly jobs average 36 s and 130 s (max 800 s); the daily jobs average 148 s and 544 s, **max 1,900 s**; the weekly job averages 423 s.

**What this changes**
- **Phase 1 is a full functional replacement** for this install: scripts, schedules, history and a CLI are all it uses.
- **A 120 s default timeout would kill real jobs.** Default to 1 hour, allow up to 6, and let import keep jobs untimed-out in practice.
- **Import belongs in Phase 1, from Cronboard's own JSON** (`cronboard list --all --json`: name, schedule, interpreter, command, enabled, timezone), not from crontab parsing in Phase 5. It is exact, needs no block parser, and ten jobs are too many to retype.
- A thin watcher whose script calls a path on one machine is **not portable** to another machine. Host choice has to be explicit and checked.
- Scripts move from cron's context to the companion's: a login-session LaunchAgent with Keychain access and a different privacy-permission identity. Expect differences on the first runs.

## 2. Does it run with the Mac app closed? (confirmed by design and on the machines)

- The scheduler is a thread in the **companion server**, and runs execute in detached runner processes. The Mac app is a client. Nothing in the run path touches it.
- On the work Mac the companion is a LaunchAgent with `KeepAlive` and `RunAtLoad`, a separate process from the app, so launchd restarts it after a crash and starts it at login.
- On the devbox the companion runs in a **tmux session with no supervisor**. A reboot or a killed session stops every watcher there until someone restarts it.
- A LaunchAgent needs a logged-in session; cron did not. After a reboot, nothing fires until login.
- launchd restarts a crashed companion but cannot see a **hung** one. The companion is also restarted for updates, sometimes several times a day.

**What this changes**
- Add scheduler liveness to the API (`scheduler: {running, last_tick_at, next_fire_at}`) and make `herdr-watchers doctor` fail when the tick is stale or the companion is unsupervised.
- **Late fires.** A restart of a few seconds must not drop a five-minute poll. When the gap since the last tick is shorter than the watcher's period (capped at 10 minutes), the missed fire runs late once, whatever `missed_runs` says. `missed_runs` governs longer gaps.
- Runtimes are installed side by side per revision, so an old runner keeps working after a swap, but **runtime pruning must skip a runtime that still has a live runner**.
- Put the devbox companion under a supervisor before it hosts anything scheduled. That is an operator step, outside this build.

## 3. Choosing the host machine (confirmed in the plan, with gaps)

The design already supports it: each companion owns its own store and scheduler, the CLI reaches any roster machine with `--machine`, and the Mac aggregates across the roster (plan §3). What was missing:

- **A way to see the choices.** `herdr-watchers machines` lists each roster machine with reachable, `watchers-v1`, enabled, supervised, timezone and executable step kinds. The Mac's picker (Phase 3) reads the same data.
- **Identity.** Watcher ids are random and globally unique; fleet views key on machine plus id.
- **Timezone default.** A watcher created on another machine defaults to the **creator's** timezone, not the host's.
- **Moving.** `export ID` writes a bundle (definition plus scripts); `import --bundle` creates it paused on the target; the source is deleted only on request. Run history and gate cursors stay behind.
- **Portability check.** Creating or importing on a machine ends with a dry run there, because scripts and tool sign-ins are per machine.
- **Offline hosts.** The CLI fails with a clear `machine_unreachable`; clients show last known state and do not edit.
- **Enabling** is per machine: `HERDR_WATCHERS_ENABLED=1` under `[machines.<id>.environment]`.

## 4. Decision, 2026-10-02: migrate every job together

The owner chose to move all ten jobs in one cutover, not one at a time. What makes that safe:

- **Preview without running.** The import's `--dry-run` compares each watcher's next fires with Cronboard's own next run and checks interpreters and timezones. It executes nothing, because these scripts post their own results and a watcher dry run of one is a real run.
- **One switch each way.** Imported watchers arrive paused. Cutover is: disable every job in Cronboard, then `resume --source cronboard`. Rollback is the reverse: `pause --source cronboard`, then re-enable in Cronboard. The import prints both command lists and runs neither.
- **No double runs.** A resumed watcher schedules from now and never catches up, so nothing fires twice for a slot Cronboard already ran.
- **Seeing failures.** `runs --source cronboard --status failed,unknown` and `doctor` after the first fires. Until the Mac destination ships, that is the only view.

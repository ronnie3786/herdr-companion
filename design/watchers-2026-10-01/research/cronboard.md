# Cronboard: what exists and what carries over (layer 1, 2026-10-01)

> Read-only sweep of `~/Documents/Development/Cronboard`, `main` at `15b6863` (1.2.3, 2026-09-06). Working tree was clean.
> Labels: **confirmed in code** unless marked *inferred*. File references are relative to the Cronboard repo.

## 0. State on this Mac

- The installed copy is **1.0.0** (`~/Applications/Cronboard.app`, `~/.local/bin/cronboard`, built Jul 28). It has no runner, no run history, and no `runs`/`logs`/`stats`/`repair` commands.
- The repo HEAD is 1.2.3. A 1.2.3 package sits in the gitignored `build/` folder but was never installed.
- `~/Library/Application Support/Cronboard` and `~/Library/Logs/Cronboard` do not exist.
- The user crontab has **0 Cronboard-managed blocks** and 2 unmanaged lines.
- **There is no live Cronboard data to migrate.**

## 1. Package layout

**`Package.swift`**
- Swift tools 6.1, Swift 6 language mode, macOS 13. No third-party dependencies.
- Products:
  - library `CronboardCore`, which links system `sqlite3`
  - executable `cronboard` (the CLI)
  - executable `cronboard-runner`
  - executable `CronboardApp` (AppKit plus ServiceManagement)
- Tests use swift-testing.

| Module | Files | Responsibility |
|---|---|---|
| CronboardCore | `CronJob.swift`, `CronExpression.swift`, `CronScheduleClock.swift`, `CrontabDocument.swift`, `CrontabStore.swift`, `JobRepository.swift`, `RunHistoryStore.swift`, `ProcessRunner.swift` | Models, cron parsing, crontab I/O, CRUD and locking, execution, SQLite history |
| CronboardCLI | `main.swift` (709 lines) | Hand-rolled argument parser and JSON envelope |
| CronboardRunner | `main.swift` (35 lines) | Short-lived process that cron starts for each run |
| CronboardApp | 10 SwiftUI files | Menu-bar popover, editor, dashboard, settings |

**Packaging and install**
- `scripts/package.sh` builds the app with the CLI and runner in `Contents/Resources/bin`, then ad-hoc signs it.
- `scripts/install.sh`:
  - copies the app to `~/Applications`
  - installs the runner atomically to `~/Library/Application Support/Cronboard/bin/`
  - symlinks the CLI into `~/.local/bin`
  - runs `cronboard repair`
- There is no Developer ID or notarization.

## 2. Data model (`Sources/CronboardCore/CronJob.swift`)

**`CronJob`** (lines 26–55) has these fields:
- `id: UUID`
- `name`
- `schedule` (5-field cron)
- `command` (the whole script body)
- `interpreter` (`bash` → `/bin/bash`, `python` → `/usr/bin/python3`)
- `isEnabled`
- `createdAt`, `updatedAt`

It has **no** timezone, metadata, args, cwd, env, timeout or description.

**Identity**
- The UUID is fixed at creation.
- Lookup tries, in order: exact UUID, then case-insensitive name, then a unique UUID prefix (`JobRepository.swift:311–334`).
- Names are not unique.

**Revisions**
- A revision id is an FNV-1a 64-bit hash of the encoded job, and `updatedAt` is part of the encoding.
- Two different hashes are in use: launcher file names hash the base64 payload (`CrontabDocument.swift:223–232`), while history `job_revisions.id` hashes the JSON string (`RunHistoryStore.swift:48–49`).

**Paths** (`CronboardPaths.live`, lines 348–358)
- `~/Library/Application Support/Cronboard`: `.crontab.lock`, `history.sqlite3`, `bin/`, `jobs/`
- `~/Library/Logs/Cronboard`

## 3. Crontab integration (the part we replace)

**Reading and writing**
- Reads with `crontab -l`; writes with `crontab -` fed on stdin (`CrontabStore.swift:15–47`).
- `CRONBOARD_CRONTAB_FILE` switches to a file-backed store for tests.

**Block format** (`CrontabDocument.swift:148–164`)
```
# >>> cronboard:v1:<base64 JSON of CronJob>
# cronboard-runner:v1
<sched> /bin/sh '<support>/jobs/<jobid>-<rev>.sh' >> '<logs>/scheduler.log' 2>&1
# <<< cronboard:<uuid>
```
- The begin-marker metadata is the source of truth. **Job bodies, including any secrets in them, end up in the crontab**, base64-encoded.
- A disabled job keeps its block but has no executable line.

**Preserving unrelated content**
- Lines outside blocks are kept, but every mutation **moves managed blocks to the end**. That reorders them relative to `VAR=value` lines, which cron applies only to later lines.
- External jobs are listed read-only. `@reboot` lines and env lines are skipped.

**Locking:** `flock` on `.crontab.lock` around each read-modify-write (`JobRepository.swift:336–353`). It does not guard against a concurrent `crontab -e`.

**Hand edits and corruption**
- Hand edits inside a block are ignored and later overwritten.
- Corrupt base64 throws `corruptManagedEntry`, which breaks every command, and there is no recovery tool.

**Hidden setup:** `prepareRunTracking` runs at app launch and before mutating CLI commands. It creates the database, installs the runner and writes revision snapshots.

## 4. Run wrapper and durable history (worth carrying forward)

**Per-run flow**
1. Cron runs `/bin/sh <jobid>-<rev>.sh` (rendered at `CrontabDocument.swift:183–213`; mode 0600, `umask 077`).
2. The launcher logs `event=dispatch`, creates a launch marker, and runs `cronboard-runner --job-file <snapshot.json> --launch-marker <marker>`.
3. The runner decodes the **immutable revision snapshot** and does not re-read the crontab. It exits with the child's exit code, or 70 if the runner itself fails (`CronboardRunner/main.swift:7–34`).
4. `execute` (`JobRepository.swift:142–253`):
   - inserts a `running` row and creates `<logs>/<jobid>/runs/<runid>/{stdout,stderr}.log` (0600);
   - runs the interpreter with the **script on stdin**;
   - adds `CRONBOARD_JOB_ID`, `CRONBOARD_JOB_NAME`, `CRONBOARD_RUN_ID`, `CRONBOARD_RUN_TRIGGER` to the environment;
   - records the status, exit code, signal (stored as 128+n), byte counts and duration.
5. **Launch-marker fallback:** if the marker still exists after the runner returns, the child never started, so the launcher runs a legacy inline fallback once. The integration tests cover a corrupt snapshot, a missing runner and a real exit of 70.
6. If the history database is unavailable, the job still runs "untracked" and logs the reason to `tracking-errors.log`.

**Storage** (`RunHistoryStore.swift:410–494`)
- SQLite at `history.sqlite3`, with WAL, `busy_timeout 5000`, `synchronous FULL` and foreign keys. Files are 0600 and directories 0700.
- Schema: `job_revisions(id, job_id, job_name, snapshot)` and `runs(id, job_id, revision_id, trigger, status, started_at, finished_at, duration_seconds, exit_code, termination_reason, termination_signal, error_message, stdout_path, stderr_path, stdout_bytes, stderr_bytes)`, with indexes on `(started_at,id)`, `job_id` and `status`.
- `user_version = 1`. There is no migration framework.

**Queries**
- Filter by job, status set, trigger and time window, with `before`-cursor pagination (1–500).
- `summary` returns counts, success rate and latest run.
- Deleted jobs can still be resolved through the revisions table.

**Not captured:** PID or heartbeat, hostname, environment, cwd, intended fire time versus actual start, runner version. A killed runner leaves its row `running` forever.

**Retention:** none. The database, logs and snapshots grow without limit.

## 5. Schedules

**Parsing** (`CronExpression.swift`)
- Exactly 5 fields. Supports `*`, lists, ranges, steps, month and weekday names, and DOW 7 as Sunday.
- No `@daily`-style macros, seconds, or `L`/`W`/`#`/`?`.

**Day-of-month and day-of-week rule**
- If either field is a wildcard, both must match (AND); otherwise either may match (OR).
- `isWildcard` is only true for a bare `*`. In Vixie cron a field that *starts* with `*`, such as `*/2`, also counts as a star, so previews of schedules like `0 9 */2 * 1` may disagree with cron. *Inferred; not checked against Apple's cron source.*

**Next run:** a minute-by-minute scan for up to 1,500 days. It is slow for rare schedules, and DST behaviour follows `Calendar`.

**Summaries and presets**
- Plain-language summaries: "Every N minutes", "Daily at", "Weekdays at", "Monthly on day…", otherwise "Custom".
- App presets: minutes, hourly, daily, weekdays, weekly, monthly, custom (`JobDraft.swift:4–76`). `inferPreset` maps an expression back to a preset.

**Timezone**
- Resolved from `/etc/localtime`; shell `TZ` is ignored. JSON output includes `scheduleTimeZone` and `nextRunLocal`.
- There is no per-job timezone.

**macOS cron limits**
- Apple's cron has a `MAX_COMMAND` of 1000 bytes. Longer lines were truncated into shell syntax errors (observed at 1,082–15,097 bytes, `docs/ARCHITECTURE.md:59–65`). The fix moved job bodies into launcher files and rejects cron lines of 1000 bytes or more.
- Every `%` in the cron line is escaped.

## 6. CLI conventions (good shape for `herdr-watchers`)

**Envelope**
- `--json` is accepted in any position.
- Success: `{schemaVersion:1, ok:true, data}` on stdout.
- Error: `{schemaVersion:1, ok:false, error}` on stderr with exit code 1.

**Commands**
- Jobs: `list [--all]`, `show`, `create|add`, `update|edit`, `enable`, `disable`, `delete --force`, `run` (synchronous)
- History: `runs [--status --trigger --since --until --limit]`, `run-info`, `logs --stream`, `stats`
- Schedules: `validate "<cron>"`, `next "<cron>" --count`
- Maintenance: `repair`, `doctor`, `version`

**Agent-friendly traits:** stable JSON, lookup by name or prefix, a required `--force` for deletes, schedule preview before saving, and a sandbox environment variable.

**Problems to avoid**
- `run` exits with the job's own exit code, so it can be confused with a CLI error.
- There is no per-command help, and `create --help` still runs setup side effects.
- No `--dry-run` and no stdin input.
- `Examples/webhook-notification.sh` posts a payload that Slack would not accept.

## 7. App UI

**Scenes:** a `MenuBarExtra` popover (440×560), a dashboard window (1120×720) and Settings.

**Popover**
- An "Up next" strip.
- One row per job: enable toggle, name, SH/PY badge, schedule summary, relative next run, ▶ Run now, and a … menu with Edit, Duplicate as Paused and Delete.
- A read-only "unmanaged entries" disclosure.

**Refresh:** polling only, every 5 s, by running `crontab -l` on the main actor.

**Run now** runs inside the app process with the app's environment, which differs from cron's, and gives only a 2.2 s toast as feedback.

**Editor:** name, interpreter, preset schedule controls with a live summary and validation, and a script text editor.

**Dashboard**
- Metrics, status and trigger filters, and 100-row pages.
- Run detail shows the frozen command, exit and signal, and the last 128 KB of stdout/stderr, refreshed every 3 s.

## 8. Tests

**Covered**
- Cron parsing and next-run, including America/Chicago across DST.
- Crontab round trip, `%` escaping, and the 1000-byte cap.
- Repository lifecycle and migration.
- History: pagination, concurrency, tracking failure, signal mapping.
- A 312-line CLI integration script against a sandboxed crontab file, including the fallback paths and a local webhook receiver.

**Not covered:** the real `crontab`/TCC path, corrupt blocks, line reordering, lock contention, `*/n` day-field semantics, DST against real cron, any UI, retention.

## 9. macOS realities

- Cron is the system LaunchDaemon `com.vix.cron`. `man launchd.plist` (macOS 26.2) says launchd's `StartCalendarInterval` starts a missed job on wake and coalesces several missed runs into one. Cron simply skips them.
- Scheduled runs get cron's minimal environment. Manual runs get the app's or CLI's environment. Scripts read from stdin can swallow the rest of the script.
- There is no timeout, overlap guard or retry.
- Full Disk Access may be needed for protected folders. Cron jobs run outside the GUI login session, so Keychain and notifications are not guaranteed there (*general knowledge*).
- There are no user notifications.

## 10. Assessment for Watchers

**Carry forward**
1. **`CronExpression` semantics and test vectors.** Fix the `*/n` wildcard rule and replace the minute scan with field-wise jumps. Port to Python for the companion, keeping the tests as golden vectors.
2. **`SchedulePreset` / `JobDraft` / `inferPreset`** for the manual schedule editor on the Mac.
3. **Run-history design:**
   - an immutable revision snapshot per run, statuses with CHECK constraints, separate stdout/stderr files with byte counts;
   - cursor pagination and summaries;
   - WAL with `busy_timeout`, 0600/0700 permissions.
   - Extend it with step runs, gate outcomes, delivery records, PID and heartbeat, `scheduled_for`, retention and real migrations.
4. **Runner pattern:** a short-lived process runs a frozen snapshot, with a launch marker so a run is never silently dropped.
5. **Process execution** (`runToFiles`), with these changes: argv/file execution instead of stdin, cwd, a timeout that kills the process group, an output cap, and an explicit PATH.
6. **CLI conventions:** the envelope, `--force`, name/prefix resolution, `validate`/`next`, `doctor`/`repair`, and a sandbox variable.
7. **Dashboard, run-detail and editor views** as starting points for the Mac run history and manual editor.

**Replace**
- **The crontab as store and trigger.** It brings the 1000-byte line limit, `%` escaping, a minimal environment, skipped runs during sleep, machine timezone only, no live status, no overlap control, and secrets written into the crontab.
- **`JobInterpreter`'s script-on-stdin**, replaced by typed steps: script, gate, agent and deliver.
- **5 s polling and in-process Run now**, replaced by runs queued to the scheduler (so every run gets the same environment) and pushed updates.

**Gaps (nothing exists today):** multi-step workflows, per-watcher state for "only if new" gates, agent steps, Slack, inbox or notification delivery, remote machines, an HTTP API, retention, retries, overlap policy and heartbeats.

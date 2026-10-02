# Watchers

Watchers are scheduled routines owned by one companion machine. Open **Watchers**
directly below **PR Review** in the Mac sidebar, or press **Command-9**. Cards show
the routine in plain English with smart chips, its computer, next fire, live
step progress, attention and past runs. The separate **Watcher inbox** holds
results. The purple Glass and Haze appearance follows the app's preferences.

**New watcher** opens a focused agent conversation with a live draft and **How it
runs** preview. The agent asks about unclear requirements, discovers the schema
and available assets, and writes a draft. Review scripts and schedule before
clicking **Create watcher**. The manual editor is available without an agent.

**Edit with an agent** creates a staged draft with its own preview. The existing
watcher keeps its schedule and scripts until the person applies the changes.
Applying verifies the original revision and updates that same watcher, preserving
its history, source and state. A conflict keeps the staged draft for reconciliation
and never creates a second active schedule.

## Enable and discover

Install a matching companion package separately from the Mac app. The signed
Mac updater never installs server packages. Watchers is off by default:

```toml
[machines.example.environment]
HERDR_WATCHERS_ENABLED = "1"
```

The environment escape hatch is compatible with older configuration readers.
The new `[watchers]` table is optional; older companions reject that table.
State lives in `watchers.sqlite3` and `watchers/` under the private state root.
Overrides are `HERDR_HARNESS_WATCHERS_STORE_PATH` and
`HERDR_HARNESS_WATCHERS_ROOT`. Scripts, revisions, runs, logs and receipts are
private local files, not source artifacts.

The companion needs a supervisor that restarts it, such as a KeepAlive LaunchAgent
or restart-enabled systemd unit. A bare tmux session is insufficient. launchd
agents require a logged-in user after reboot. Supervision is detected from the
service environment; when needed, set `HERDR_WATCHERS_SUPERVISED=1` only after
verifying the installed supervisor. `herdr-watchers doctor` fails for disabled,
stopped, stale or unsupervised schedulers and explains recovery.

`GET /api/v1/watchers/capabilities` always responds, including when disabled:
`{ok, enabled, capabilities, machine, timezone, steps, delivery, limits, assets,
summary_tokens, scheduler, supervised}`. Disabled companions advertise no
Watchers capability, construct no store or scheduler, and return 503
`watchers_disabled` for other Watchers routes. Updated enabled companions expose
`watchers-v1` in `GET /api/v1`. The health response also includes
`scheduler: {running, last_tick_at, next_fire_at}`.

This version executes script, gate and inbox delivery steps. Agent and external
delivery definitions can be saved as drafts, but activation, run now and dry run
reject unsupported steps with `step_kind_unsupported`. The CLI and builder must
read each machine's capabilities rather than assuming identical versions.

## Agent and CLI workflow

`herdr-docs read watchers` is the bundled agent guide. `herdr-watchers schema`
returns the closed definition schema, icon and avatar catalogs, chip rules and
script limits. `herdr-watchers example` returns a synthetic `{definition,scripts}`
bundle. The agent builder uses the `watcher-builder-v1` profile, normal Pi skill
discovery, an explicit Watchers charter and durable chat snapshots. If its process
is interrupted, saved drafts remain; it does not pretend unfinished turns ran.

All CLI commands accept `--machine ID`, `--config FILE` and `--request-id ID`.
Remote commands use that machine's own configured credential. JSON goes to stdout;
errors go to stderr with exit 2, or exit 4 for HTTP 409 conflicts. The selected
host's capability is checked before operations. Local `schema`, `example`, and
`validate --definition-file FILE` need no running server.

```sh
herdr-watchers machines
herdr-watchers capabilities --machine example
herdr-watchers draft create --definition-file definition.json --scripts-file scripts.json
herdr-watchers script get WATCHER_ID --step check
herdr-watchers schedule preview '{"kind":"interval","every_minutes":15}' --timezone UTC
herdr-watchers dry-run WATCHER_ID --wait
herdr-watchers activate WATCHER_ID --i-confirm
herdr-watchers pause WATCHER_ID
herdr-watchers resume WATCHER_ID
herdr-watchers run-now WATCHER_ID --wait
herdr-watchers runs WATCHER_ID
herdr-watchers logs RUN_ID --step check --stream stdout
herdr-watchers stop RUN_ID
herdr-watchers inbox --unread
herdr-watchers doctor
```

Activation is intentionally absent from agent discovery. A person reviews and
clicks **Create watcher**, or uses `activate --i-confirm`. The API requires
`confirmed_by: "user"` and stores `activated_by` and `activated_via`. Agents have
the main token, so this is an audit convention, **not a security boundary**.
Scoped scheduling credentials remain future work.

## Definitions, schedules and smart chips

A definition has `name`, `timezone`, `schedule`, `summary` and ordered `steps`.
The schema describes all four step kinds: `script`, `gate`, `agent`, `deliver`.
Optional metadata includes `avatar`, `created_by`, `source_prompt`,
`builder_session_id`, `missed_runs`, and `overlap`. The server stamps its machine
identity and rejects a mismatching client value. Every change, including script
content and state changes, increments `revision`. Runs pin immutable copies of
the definition and scripts. Script files are at most 256 KiB each.

Schedules use IANA timezones and are calculated without a minute-by-minute scan:

| Kind | Fields |
| --- | --- |
| `interval` | `every_minutes` (1 through 1440), optional `days` and `[start,end]` window |
| `daily` | `at` (`HH:MM`), optional `days` |
| `cron` | Five-field `expression`, with names, ranges and steps |
| `once` | ISO date-time `at` |

Days are `all`, `weekdays`, or ISO weekday integers (Monday 1 through Sunday 7).
Intervals align from local midnight. Windows are half-open, so the ending minute
does not fire. Cron uses Vixie DOM/DOW semantics, including fields beginning with
`*`; cron Sunday is 0 or 7. Fixed times in a daylight-saving gap fire once at the
first valid minute after the gap, and overlap times fire only once. Impossible
schedules return a bounded no-next-run result. A one-time watcher becomes done.

The default missed-run policy skips frequent intervals and runs daily or weekly
routines once after a longer gap. A short restart or sleep gap, shorter than the
period capped at ten minutes, fires late once as scheduled. Longer gaps apply
`skip` or `run_once` (one `catch_up` run). Resume starts scheduling from now and
never catches up. Overlapping runs are skipped. Capacity defaults to four runs
and can be set with `HERDR_WATCHERS_MAX_RUNS`.

The server preserves raw `summary` markup and adds `summary_text`, safe
`summary_tokens` and warnings. Tokens are `{time}`, `{gh:…}`, `{script:file}`,
`{agent:Name}`, `{skill:name}`, `{slack:#channel}`, `{inbox:…}`, `{repo:…}`,
`{pc:Machine}`. Every summary contains `{time}`. The four step-bound tokens must
match the steps. Unknown or mismatched tokens render as text, never as a false
claim about an action. No nesting or braces inside token values are allowed.
Clients keep punctuation attached to its chip and use `schedule.summary` for the
time phrase. Instructions and actions remain typed step fields, not executable
summary markup. Assets are the approved Original characters and instruments.

## Execution and recovery

The manager holds `watchers/manager.lock`, sleeps until the next fire (at most
30 seconds), and wakes after mutations. It runs without any connected client.
Each run launches `[sys.executable, "-P", "-m", "herdr_harness.watchers.runner",
"--run", run_dir]` in its own session, holds `runner.lock`, and heartbeats every
five seconds. Service stop leaves runners alive. A lost runner becomes `unknown`
only after its lock is free and its heartbeat is older than three intervals;
the Watcher inbox then says it needs you.

Scripts execute their pinned file with an explicit interpreter, working directory,
PATH, timeout and process-group cancellation. The default timeout is one hour,
maximum six hours. Logs stay on disk; API log views are bounded. Script results
come from `HERDR_WATCHER_OUTPUT` when present, otherwise stdout. Exit 75 means
**Nothing new** in this contract, despite its conventional `EX_TEMPFAIL` meaning.
Any other nonzero exit needs attention.

The script environment removes Herdr administrative settings and tokens. It adds
`HERDR_WATCHER_ID`, `HERDR_WATCHER_RUN_ID`, `HERDR_WATCHER_STEP_ID`,
`HERDR_WATCHER_INPUT`, `HERDR_WATCHER_OUTPUT`, and `HERDR_WATCHER_STATE_DIR`.
PATH comes from `HERDR_WATCHERS_PATH` or system defaults plus the companion bin.
HOME, USER, LOGNAME, SHELL, TMPDIR and LANG support imported cron scripts.
Scripts that explicitly export HOME or PATH retain their own behavior.

`new_items` checks compare JSON item keys and optional versions; `changed` checks
compare the whole prior output. Cursors commit only after successful deliveries,
or after a successful run with no delivery, and keep at most 5,000 newest keys.
Dry runs use the same execution path, commit no cursor, and record inbox delivery
as **would post**. They cannot suppress effects inside arbitrary script bodies.

The hourly retention sweep retains the most recent 200 runs plus all runs in the
last 30 days, removing older rows and log directories. Inbox retention is 90 days.
Runtime pruning skips any installed runtime still hosting a live watcher runner.

## Cronboard migration, cutover and rollback

Export all jobs on the machine where they run using
`cronboard list --all --json`. Keep this file private. Never copy it into source,
tests or screenshots. Review every interpreter, script path and external effect.

```sh
herdr-watchers import --cronboard-json /private/path/cronboard.json --dry-run --machine example
herdr-watchers import --cronboard-json /private/path/cronboard.json --i-confirm --machine example
```

The first command executes nothing and creates nothing. For each job it shows
three proposed next fires beside Cronboard's next run, checks timezone and syntax,
and reports whether the interpreter exists on the target. Review any parity
mismatch or missing Cronboard next-fire evidence before proceeding.

Import is all-or-nothing and idempotent by Cronboard job ID. Enabled jobs arrive
**resting** only with `--i-confirm`, recording the person's confirmation. Otherwise
they are drafts. Disabled jobs remain drafts regardless. Each job preserves its
body, schedule, timezone and interpreter in one script step, with a one-hour
timeout, instrument avatar and generated chip summary. Python uses
`/usr/bin/python3`; bash uses `/bin/bash`.

Import prints exact `cronboard disable JOB_ID` lines for the previously enabled
jobs and matching `cronboard enable JOB_ID` rollback lines. It does not run these
commands or edit a crontab. Keep the original enabled set for rollback.

After reviewing the import, cut over together: disable the previously enabled
Cronboard jobs using those printed commands, wait for any in-flight Cronboard
runs to finish, then:

```sh
herdr-watchers resume --source cronboard --machine example
herdr-watchers doctor --machine example
herdr-watchers runs --source cronboard --status failed,unknown --machine example
```

Only resting imported watchers resume. Disabled drafts stay unscheduled. Resume
starts from now so completed Cronboard slots are not repeated. Keep an eye on
first results because launchd/companion permissions can differ from cron.

Rollback: `herdr-watchers pause --source cronboard --machine example`, stop or wait
for any active Watcher runs, then execute the printed enable lines to restore the
original Cronboard enabled set. Pausing prevents new fires; it does not kill a
running job. Verify both systems before leaving one active.

To move a routine between computers, `export ID` includes its definition and
scripts. `import --bundle FILE --machine TARGET` creates it resting, never deletes
the source, and leaves history and gate cursors on the original host. Review
machine-specific paths, credentials and permissions, then explicitly activate.

## HTTP contract

All routes below have prefix `/api/v1/watchers`, require main-token authentication,
and return `{ok:true,…}` or `{ok:false,error:{code,message}}`. Mutation bodies
reject unknown keys and require `request_id`. Replaying a receipt with different
content returns 409 `idempotency_conflict`. Definition updates require the exact
integer `expected_revision`; conflicts return 409 `revision_conflict`.

| Method and route | Body or result |
| --- | --- |
| GET `/capabilities` | Discovery above, always available |
| GET `/` | `{watchers:[…]}`, optional `state`, `source` |
| POST `/` | `{request_id,definition,scripts?}` → `{watcher}` draft |
| GET `/{id}` | `{watcher}` |
| PATCH `/{id}` | `{request_id,expected_revision,definition,scripts?}` → `{watcher}` |
| DELETE `/{id}?force=1` | `{request_id}`; active/live watchers refuse without force |
| POST `/{id}/actions` | `{request_id,action,confirmed_by?,activated_via?}` |
| POST `/actions` | `{request_id,action:pause\|resume,source:cronboard}` |
| GET/PUT `/{id}/scripts/{step}` | GET `{script:{step_id,file,content,exists,revision}}`; PUT `{request_id,expected_revision,content}` |
| POST `/schedule/preview` | `{schedule,timezone,count?}` → `{summary,next:[UTC ISO]}` |
| GET `/{id}/runs` or `/runs` | `{runs}`, optional `status`, `source`, `limit`, per-watcher `before` |
| GET `/runs/{id}` | `{run}` including step results |
| GET `/runs/{id}/logs` | `step`, `stream` → `{content,truncated,…}` |
| POST `/runs/{id}/stop` | `{request_id}` → `{run}` |
| GET `/inbox` | `{items}`, optional `unread=1`, `source`, `before`, `limit` |
| POST `/inbox/{id}/read` or `/inbox/read-all` | `{request_id}` |
| GET `/{id}/export` | `{bundle:{definition,scripts}}` |
| POST `/import` | `{request_id,source:cronboard\|bundle,jobs?\|bundle?,dry_run?,confirmed_by?,timezone?}` |
| POST `/builder/sessions` | `{request_id,watcher_id?,timezone?}` (creator's IANA timezone) |
| GET `/builder/sessions/{id}` | `{session_id,status,messages,tools,draft}` |
| POST `/builder/sessions/{id}/messages` | `{request_id,text}` → snapshot plus `turn_id` |

Actions are `activate`, `pause`, `resume`, `run_now`, `dry_run`, and `duplicate`.
List/detail payloads carry the flattened definition plus `state`, `kind`,
`machine:{id,name}`, `schedule.summary`, `next_fire_at`, `live`, `attention`,
`last_run`, `runs_count` and `unread_inbox`. Live status has `run_id`, `step_index`,
`step_count`, `step_id`, `step_title`, `started_at`. Progress reflects completed
steps, never elapsed time. Run outcomes are `queued`, `running`, `finished`,
`nothing_new`, `failed`, `stopped`, and `unknown`, with duration and a plain-language
summary. SSE events are `watchers.updated`, `watchers.run`, `watchers.inbox` and
`watchers.builder`. Older clients and companions remain independently usable.

# Watchers in Herdr: implementation plan

**Layer 1, 2026-10-01.** This is what one investigation found and proposes. It is reference, not a spec.

> **Read this first.** Verify claims before building on them, and follow the evidence where it disagrees with this doc. Add new findings as a dated layer, such as `FINDINGS-<date>.md`, instead of rewriting this one.
>
> **Labels**
> - **confirmed**: checked in code
> - *inferred*: reasoned, not checked
> - **proposal**: a direction, not a prescription
>
> **Sources**
> - `research/cronboard.md`: Cronboard `15b6863`
> - `research/herdr-architecture.md`: herdr-companion `origin/main` at `eac13aa`
> - The approved design: `design/watchers-prototype/avatars-v1-chips.html`, plus `v2-core.js` (data, chips, builder) and `v2-avatar-styles.js` (the Original critters)

---

## 1. What we're building

A **watcher** is a small, named routine that runs on one machine on a schedule. It works through a list of steps and reports what it found.

**Steps**
- **Script**: a deterministic shell or Python script. No agent, so it costs no tokens.
- **Check** (gate): "continue only when something is new". If nothing changed, the run stops early and nothing is sent.
- **Agent**: an agent (shown by its model's display name: Astra, Sol, Luna) runs a skill with instructions.
- **Deliver**: posts to a Slack channel, saves to the Watcher inbox in Herdr, and optionally sends a Mac notification.

**How it looks** (the approved V1 + chips design)
- Each watcher has an avatar:
  - a **critter** (the Original set: owls, cats, foxes, bots and more) if any step uses an agent;
  - an **instrument** (gauge, cog, hourglass…) if it only runs scripts.
- Each has a first-person summary with smart chips:
  > Every 15 min, I look for [GitHub: open PRs that request your review]. When something is new, [Sol] runs [🤖 pr-review-triage] and I post the results to [Slack #agentic-monitoring].

**States**
- **Draft**: built, not scheduled.
- **On watch**: active.
- **Resting**: paused.
- **Done**: a one-time watcher that has run.
- **Needs you**: the last run failed or couldn't deliver.

**Run outcomes**
- **Finished**
- **Nothing new**: stopped at a check.
- **Failed**
- **Stopped**: by you.
- **Unknown**: the runner disappeared mid-run.

**Creating one.** In the Mac app, **New watcher** opens a chat with Astra, the default agent on that machine.
1. You describe the job in plain English.
2. Astra repeats back what it heard as chips. It checks that things exist (`gh` sign-in, the skill, the agent, the Slack channel) and writes the scripts for the deterministic parts.
3. It saves a **draft**, which appears as a card with its steps. You can refine it in chat ("make it every 30 minutes on weekdays", "use Luna", "no agent").
4. Run a **dry run** (nothing is delivered), then click **Create watcher**.
- **Only a human click puts a watcher on watch.**
- **Edit with Astra** works the same way on an existing watcher. A manual editor is the fallback.

---

## 2. Cronboard as the foundation: what carries over, what changes

Cronboard proved the core product loop: a menu-bar UI plus an agent-friendly CLI, durable run history, and frozen revisions. **Its execution engine, the system crontab, is the part to replace.**

- The crontab truncates lines over 1000 bytes and gives jobs a minimal environment.
- It skips runs while the Mac sleeps and only knows the machine timezone.
- It has no live status or overlap control.
- It writes job bodies, including any secrets in them, into the crontab.

Watchers also need things Cronboard never had: agents, skills, Slack, an HTTP API, and multiple machines. All of those already live in the Herdr companion (research §2–§5).

**Recommendation:** Watchers is **Cronboard's model and ergonomics, re-homed into the Herdr companion**. Cronboard stays as reference code and as a source for the crontab import. It is not a dependency.

| Cronboard piece | Watchers | How |
|---|---|---|
| `CronJob` + revision snapshots | Watcher definition with an integer `revision`. Runs pin an immutable revision snapshot. | Port the idea. Use a single hash or counter, not Cronboard's two hashes. |
| `CronExpression` + tests | Python `watchers/schedule.py` | Port, and keep the Swift tests as golden vectors. Fix the `*/n` day-field rule and the minute scan (research cronboard §5). Add per-watcher timezones with `zoneinfo`. |
| `SchedulePreset` / `inferPreset` / editor controls | Mac manual editor (§9.6) | Port to the Mac target. Use the server's preview endpoint for next runs. |
| `RunHistoryStore` (SQLite, WAL, cursor pages, summaries, separate stdout/stderr) | `watchers.sqlite3`: `runs`, `step_runs`, `deliveries` | Same conventions, plus step rows, gate outcomes, PID and heartbeat, `scheduled_for`, retention, and real migrations (follow `FirstMateStore`). |
| `cronboard-runner` + launch marker | Detached per-run worker `python -m herdr_harness.watchers.runner --run <dir>` | Same "frozen snapshot, never silently dropped" idea. It survives companion restarts, the way First Mate runners do. |
| `FoundationCommandRunner.runToFiles` | Script step executor | Run argv/files instead of piping the script on stdin. Add cwd, a timeout that kills the process group, an output cap and an explicit PATH. Reuse `pr_review_runtime._run_process_group`. |
| CLI envelope, `validate`/`next`, `--force`, name/prefix lookup, `doctor`/`repair` | `herdr-watchers` CLI (§7) | Follow Herdr's CLI conventions: errors as JSON on stderr, exit 2/4, `--request-id`. Keep Cronboard's verbs. |
| Popover "Up next", Run now, dashboard, run detail | Mac "Next to wake" pill, card actions, run history sheet, run detail | Rebuilt in the V1 + chips design. |
| Crontab parsing of managed and external lines | `herdr-watchers import --crontab` | Import entries **paused** for review. Never edit the crontab automatically. |
| Crontab as store and trigger | **Dropped** | Replaced by the companion scheduler. |

**Considered and not chosen**
- **Grow Cronboard into a Swift LaunchAgent daemon on every machine.** It would duplicate the companion's API, auth, roster, Pi and skills plumbing in a second language and add a process to deploy. The devbox runs its companion in tmux, not launchd.
- **One launchd plist per watcher.** launchd catches up after sleep, but its calendar keys can't express ranges or steps. It also scatters state across `~/Library/LaunchAgents` and gives no live status.

---

## 3. Architecture

```
Mac app ── Watchers destination (V1 + chips) ──── HTTP + SSE per machine ─────┐
  │  WatchersStore (fleet-wide, like FirstMateFleetIndex)                       │
  │  Builder sheet: chat with Astra + live draft card                            │
  ▼                                                                              ▼
Companion on each machine (herdr_harness)
  watchers/store.py      watchers.sqlite3: definitions+revisions, drafts, runs, step_runs,
                         gate cursors, inbox items, deliveries, receipts
  watchers/schedule.py   cron/interval/once → next fire; timezone; missed-run policy
  watchers/runtime.py    scheduler thread (manager.lock), queue, concurrency, reattach
  watchers/runner.py     detached worker per run: executes steps from a frozen snapshot
  watchers/steps/*.py    script | gate | agent (Pi with skills) | deliver (outbox)
  server.py              /api/v1/watchers/* + capability watchers-v1 + SSE events
  scripts/herdr_watchers_cli.py   herdr-watchers (agents and people)
  agent profile "watcher-builder-v1"   the chat that builds drafts
```

**Where a watcher runs.** Each watcher lives in the store of the companion on its machine, shown by the computer chip.
- The Mac aggregates across the roster, the way First Mate fleet polling does (research §6–7).
- **Default host: the machine you build it from. Suggest the always-on devbox for anything every hour or more often** (open decision D2).

**Why in-process plus detached runners.**
- The scheduler thread follows the existing pattern: PR Review's 2 s loop with `manager.lock`.
- Runs execute in detached worker processes. **Companion updates restart the server, and agent runs started through `AgentRunManager` are cancelled on stop** (research §2a). Detached workers keep a 20-minute agent step alive across a restart. The scheduler reattaches to them through per-run locks, as First Mate does.

---

## 4. Data model (proposal)

### 4.1 Definition (one revision)

```json
{
  "id": "wat_7f3c…", "revision": 3, "state": "active",
  "name": "PR radar", "avatar": "hoot", "machine": "desktop",
  "timezone": "America/Chicago",
  "schedule": { "kind": "interval", "every_minutes": 15, "days": "weekdays", "window": ["08:00", "18:00"] },
  "missed_runs": "skip", "overlap": "skip",
  "summary": "{time}, I look for {gh:open PRs that request your review}. When something is new, {agent:Sol} runs {skill:pr-review-triage} and I post the results to {slack:#agentic-monitoring}.",
  "steps": [
    { "id": "find", "kind": "script", "title": "Find PRs that request your review",
      "file": "find-review-requests.sh", "interpreter": "zsh", "timeout_seconds": 120, "icon": "github" },
    { "id": "new", "kind": "gate", "title": "Continue only when a PR is new or updated",
      "rule": { "kind": "new_items", "from": "find", "key": "url", "version": "updatedAt" } },
    { "id": "triage", "kind": "agent", "title": "Triage what changed",
      "model": "openai-codex/gpt-6-sol", "skill": "pr-review-triage",
      "instructions": "Summarize each PR and say which to look at first.", "timeout_seconds": 1800 },
    { "id": "post", "kind": "deliver",
      "to": [ { "kind": "slack", "target": "#agentic-monitoring" }, { "kind": "inbox" } ] }
  ],
  "created_by": "agent:watcher-builder", "source_prompt": "I want to set up a watcher…",
  "created_at": "…", "updated_at": "…"
}
```

**Schedule kinds**
- `interval`: `every_minutes`, with optional `days` and a time `window`.
- `daily`: `at` plus `days` (all, weekdays, or a list).
- `cron`: a 5-field expression, kept for imports and power users.
- `once`: an ISO date-time.

**Policies**
- **Missed runs:** `skip` or `run_once` (catch up with one run on wake or restart). Default `skip` for intervals of an hour or less, `run_once` for daily and weekly schedules (D5).
- **Overlap:** `skip`, so a new fire is dropped while the previous run is still going. `queue` can come later.

**Scripts** live with the revision: `watchers/<id>/rev-<n>/<file>` (0700 directory, 0600 files). A run executes its pinned revision's copies. **No secrets in scripts or definitions.** Credentials come from the private config or the Keychain (§5.6).

### 4.2 Summary markup (smart chips)

The summary is markup, not structured JSON. The builder agent writes it, the server validates it, and clients render it.

**Tokens**

| Token | Chip |
|---|---|
| `{time}` | the live schedule; no value is stored |
| `{gh:…}` | GitHub mark |
| `{script:file}` | terminal glyph |
| `{agent:Name}` | small face |
| `{skill:name}` | 🤖 |
| `{slack:#channel}` | Slack logo |
| `{inbox:…}` | tray |
| `{repo:…}` | folder |
| `{pc:Machine}` | computer |

**Server validation**
- `{time}` must appear.
- Each `{script}`, `{agent}`, `{skill}` and `{slack}` value must match the steps.
- Unknown or mismatched tokens are downgraded to plain text, with a warning in the response.
- Trailing punctuation stays attached to its chip (the prototype's `.nw` rule).

**Why markup:** the grammar is easy for the agent to write, and the validator keeps it honest. The renderers are in `v2-core.js` (`says()`), and the chip palette is in §9.4.

### 4.3 Runs, steps, inbox

- **`runs`**:
  - `id`, `watcher_id`, `revision`, `trigger` (scheduled, manual, dry_run, catch_up)
  - `scheduled_for`, `started_at`, `finished_at`
  - `status`: queued, running, finished, nothing_new, failed, stopped, unknown
  - `pid`, `heartbeat_at`, `summary`
- **`step_runs`**:
  - `run_id`, `step_id`, `status` (ok, skipped, failed, timed_out), exit code or signal
  - stdout/stderr paths and byte counts (Cronboard's layout)
  - `output_ref`: the file handed to the next step
  - for agent steps: `pi_session_id`, `cost_usd`, `response_ref`
- **`gate_state`**: `watcher_id`, `step_id`, `cursor_json`, `updated_at`. This holds the item keys and versions already seen.
- **`inbox_items`**: `id`, `watcher_id`, `run_id`, `title`, `body_md`, `created_at`, `read_at`. This is the **Watcher inbox**. The name avoids the existing Work Inbox (D4).
- **`deliveries`**: an outbox, one row per run and destination, with `status` pending, sent, failed or unknown and `attempts`. **No automatic resend after an uncertain send**, copied from `first_mate_notifications.py` (research §5).
- **`receipts`**: `request_id` idempotency (the `FirstMateStore` pattern).
- **`drafts`**: the same shape as a definition, with `state: "draft"`, plus `builder_session_id`.

**Retention** (Cronboard had none): keep 30 days or 200 runs per watcher, whichever is larger, and delete log files with their rows. Inbox items stay until you delete them or 90 days pass (D11).

---

## 5. Companion: how it functions

### 5.1 Scheduler (`watchers/runtime.py`)
- A lazy `HerdrService.watchers` property, started from `service.start()` **only when enabled** (§5.7).
- Takes `watchers/manager.lock` with `flock`, so only one scheduler runs per state directory.
- **Each tick (1 s):** find active watchers whose `next_fire_at` is at or before now, then check the overlap policy and capacity.
  - Insert a `runs` row (`queued`) with `scheduled_for`.
  - Spawn a detached runner and store `next_fire_at` from `schedule.py`.
- **Catch-up:** on start and after a long gap (sleep or restart, measured from the last tick), apply `missed_runs` per watcher. `run_once` creates a single `catch_up` run.
- **Reattach:** at start, any `running` row whose runner lock is free and whose heartbeat is stale becomes `unknown` and gets a "needs you" inbox item. Its deliveries stay as they are, so nothing is double-posted.
- **Capacity:**
  - script runs: up to 4 at once (`HERDR_WATCHERS_MAX_RUNS`);
  - agent steps: up to 1 per machine (`HERDR_WATCHERS_MAX_AGENT_STEPS`), separate from the two `AgentRunManager` HUD slots.

### 5.2 Runner (`watchers/runner.py`)
- Started as `python -m herdr_harness.watchers.runner --run <run-dir>` in its own session and process group, holding `<run-dir>/runner.lock`.
- Reads the **frozen revision snapshot** and steps through it in order, writing each `step_runs` row and its log files, and updating the heartbeat every 5 s.
- **Environment:**
  - an explicit PATH built from config, because there is no login shell under launchd (research §1 and §9);
  - `HERDR_WATCHER_ID`, `HERDR_WATCHER_RUN_ID`, `HERDR_WATCHER_STEP_ID`;
  - `HERDR_WATCHER_INPUT`: the previous step's output file;
  - `HERDR_WATCHER_OUTPUT`: where this step writes its result;
  - `HERDR_WATCHER_STATE_DIR`.
  - **No Herdr API token in script steps**, unless a later decision adds it.
- **Stop:** `POST /watchers/runs/{id}/stop` signals the process group (SIGTERM, then SIGKILL after 10 s). The run is marked `stopped`, and its deliveries are not sent.

### 5.3 Step executors

**Script**
- Runs the pinned file with its interpreter (`zsh`, `bash`, `python3`) in a cwd (the default is the run directory).
- Has a timeout and a 2 MiB output cap (the full logs stay on disk).
- Exit 0 means ok.
- **Exit 75 (`EX_TEMPFAIL`) means "nothing to do"**: the run stops as `nothing_new` and is not counted as a failure. Any other non-zero exit fails the run.

**Gate**
- Built-in rule `new_items`:
  1. Parse the earlier step's output as JSON (an array, or `{items:[…]}`).
  2. Key each item by `key`, plus `version` if given.
  3. Compare against `gate_state.cursor_json` and pass **only the new items** to the next step.
  4. If there are none, stop as `nothing_new`.
- The cursor is committed **after** the run's deliveries succeed, so a failed run retries the same items.
- A `changed` rule hashes the whole previous output.
- Prior art: `herdr_pr_review_watch.py` (research §9).

**Agent**
- Runs Pi directly from the runner, so it survives server restarts. It uses a `PiRunner` variant (`code_factory/pi.py`) **with skills enabled**: drop `--no-skills`, and prefix the prompt with `/skill:<name>` when a skill is set (`pr_review_runtime.py:589-596`).
- The prompt is a charter (role, untrusted-input rules, "write your result as Markdown"), the instructions, and the previous step's output fenced as **untrusted data**.
- Model is `--model <id>`; the display name comes from `PiModelDisplayName`.
- Tools: ask mode by default (`read,bash,grep,find,ls`); act mode only if the watcher opts in (D9).
- Records session id, cost, response and timeout. The response becomes the next step's input.

**Deliver**
- Writes `deliveries` rows, then sends:
  - **Inbox**: a row plus the SSE event `watchers.inbox`.
  - **Slack**: through the configured adapter (§5.6).
  - **Mac notification**: through SSE. The Mac posts a local notification, as it does for PR Review walkthroughs. iPhone push comes later.
- Outbound text is scrubbed for tokens, as Code Factory does.

### 5.4 Dry run
- Uses the same runner with trigger `dry_run`.
- The gate never commits its cursor, and delivery is replaced by "would post to …" records.
- The result is attached to the draft and shown in the builder.

### 5.5 Safety
- Only a human action makes a watcher active. Drafts can be created by agents. `POST /watchers/{id}/activate` requires the main token **and** a `confirmed_by: "user"` field that the Mac sets on a click (D6).
- Content fetched by scripts and agents is untrusted. The agent charter says so, and agent steps run in ask mode by default.
- Scripts run as the operator, unsandboxed, like `panes/{id}/run` today. The builder charter forbids destructive commands without the user saying so explicitly.

### 5.6 Slack
**There is no Slack code in Herdr today** (research §5). Two adapters, chosen in private config:
- **`cli`** (default; you already have a Slack CLI): a command template, for example `["slack", "chat", "send", "--channel", "{channel}", "--text-file", "{file}"]`. The companion runs it once per delivery and records the result.
- **`api`**: a bot token as `{file=…}` or `{env=…}`, posting with `chat.postMessage` over `urllib`.

Either way, tokens never appear in definitions, scripts, argv or logs. The builder's existence check uses the same adapter (`conversations info`).

### 5.7 Config and rollout
- `[watchers]` is **not** an allowed top-level section yet (`config.py:340`). Adding one would break every older companion that reads the shared file.
- **Step 1:** ship the companion with:
  - `watchers` in the allow-list
  - `ENVIRONMENT_FIELDS` entries mapping to `HERDR_WATCHERS_*`
  - the feature **off unless `HERDR_WATCHERS_ENABLED=1`**, set under `[environment]` or `[machines.<id>.environment]`
- **Step 2:** once every companion is upgraded, move settings into `[watchers]` and `[watchers.slack]`.

---

## 6. API (`/api/v1/watchers`, main-token scope; proposal)

**Capability and discovery**
- `GET /watchers/capabilities` returns:
  - `{capabilities:["watchers-v1"], enabled, machine, timezone, models:[{id,display}], skills:[…], delivery:{slack:bool, inbox:true, notify:true}, limits}`
- Also add `watchers-v1` to `api_description()`.

**Watchers**
- `GET /watchers` returns `[{…definition, next_fire_at, last_run:{status,finished_at,summary}, unread_inbox}]`
- `POST /watchers` creates a draft: `{request_id, definition}` → `{watcher}`
- `GET /watchers/{id}`, `PATCH /watchers/{id}` (`{request_id, expected_revision, definition}`) and `DELETE /watchers/{id}?force=1`
- `POST /watchers/{id}/actions` with `{request_id, action}`. Actions: `activate` (needs `confirmed_by:"user"`), `pause`, `resume`, `run_now`, `dry_run`, `duplicate`.

**Schedules:** `POST /watchers/schedule/preview` with `{schedule, timezone, count}` returns `{summary, next:[…]}` (Cronboard's `validate`/`next`).

**Runs**
- `GET /watchers/{id}/runs?status=&before=&limit=` and `GET /watchers/runs/{run_id}`
- `GET /watchers/runs/{run_id}/logs?step=&stream=`
- `POST /watchers/runs/{run_id}/stop`

**Inbox:** `GET /watchers/inbox?unread=1&before=`, `POST /watchers/inbox/{id}/read`, `POST /watchers/inbox/read-all`

**Builder**
- `POST /watchers/builder/sessions` with `{request_id, watcher_id?}` returns `{session_id}`
- `POST /watchers/builder/sessions/{id}/messages` with `{request_id, text}` returns `{turn_id}`
- `GET /watchers/builder/sessions/{id}` returns the transcript, tool rows, written files, and the current draft (§8)

**Import:** `POST /watchers/import` with `{request_id, source:"crontab"}` returns paused drafts.

**SSE events:** `watchers.updated`, `watchers.run` (status and step changes), `watchers.inbox`, `watchers.builder`.

**Conventions:** exact body keys, `request_id` replay with `idempotency_conflict`, errors in `{ok:false,error:{code,message}}`, additive fields. Add the routes to the client timeout table (§9.2).

---

## 7. CLI: `herdr-watchers` (for Astra and for you; proposal)

- Entry point: `pyproject.toml` `herdr-watchers = herdr_harness.commands:watchers` → `scripts/herdr_watchers_cli.py`.
- Follows the NotesClient family: HTTPS, or HTTP on loopback only; JSON output; errors on stderr; exit 2 for errors, 4 for conflicts; `--request-id`; capability pre-check.
- `--machine` reaches another roster machine through `control_cli.machine_client`.

```
herdr-watchers capabilities
herdr-watchers list [--state active|paused|draft] | get ID
herdr-watchers draft create --definition-file -          # JSON on stdin
herdr-watchers draft update ID --expected-revision N --definition-file -
herdr-watchers script put ID --step find --file find-review-requests.sh < script
herdr-watchers schedule preview '{"kind":"interval","every_minutes":15}' [--count 5]
herdr-watchers dry-run ID [--wait]
herdr-watchers pause|resume ID     run-now ID [--wait]     delete ID --force
herdr-watchers runs ID [--status …] | run RUN_ID | logs RUN_ID [--step S --stream stdout]
herdr-watchers inbox [--unread] | read ITEM_ID
herdr-watchers check gh | slack '#channel' | skill NAME | agent MODEL   # builder existence checks
herdr-watchers import --crontab [--dry-run]
herdr-watchers doctor
```

**What the CLI cannot do:** `activate` is not exposed to agents. A person can run `herdr-watchers activate ID --i-confirm`. The Pi discovery text tells agents to ask the user to click **Create watcher** instead.

**Agent discovery**
- Add `pi-semantic-bridge/extensions/watchers-discovery.ts`, active for panes, agent runs **and** the First Mate lead (`HERDR_FIRST_MATE_MANAGED_ROLE`).
- Add an `agent-docs/overview.md` entry and a `herdr-docs watchers` topic.
- Put the companion CLI wrappers on the agent PATH; they are not there today (research §2a).

---

## 8. The AI builder

**Who builds:** a dedicated **builder session** on the target machine, a new agent-run profile `watcher-builder-v1`.
- It is multi-turn like HUD chats and keeps skills so it can inspect them.
- Its charter covers: the watcher schema and chip markup, using `herdr-watchers` for every change, writing scripts for deterministic work, using a gate before any agent step on polled data, preferring delivery adapters to hand-written Slack calls, and never activating.

**Why not the First Mate lead chat:**
- the sheet needs a focused, disposable conversation;
- the lead has a closed tool set that would need new typed tools;
- the lead must not schedule work unattended.

The lead *can* still create drafts through the CLI once discovery is in place. Its drafts show up in the Watchers destination with a "Draft from First Mate" label (D7).

**Turn flow** (matches the prototype's thread):
1. The user's message is posted to the session.
2. Astra replies with "Here's what I heard" plus chips. The Mac renders chip markup in message text with the same renderer as cards.
3. Tool rows stream in as `watchers.builder` events: `herdr-watchers capabilities`, `check gh`, `check skill …`, `check slack …`, `script put …`, `draft create`.
4. The draft card updates live from `GET /watchers/builder/sessions/{id}`.
5. Astra closes with a short note, such as "The search and the Slack post are scripts, so Sol only wakes when there's something new. Want a dry run?"

**Avatars:** the server picks a random unused avatar of the right family (critter if an agent step exists, otherwise instrument). The Mac offers Shuffle and Choose. Switching between script-only and agent re-picks the avatar from the other family.

---

## 9. Mac app

### 9.1 Navigation
**Add `HerdrDetailScope.watchers` and wire it through every switch** (research §6):
- `AppRootView`:
  - `show`, `resolvedScope`, `currentDestination`, `apply`, `isAlive`, `agentControlSegment`
- `NavigationHistory.HerdrDestination`, with record kind `"watchers"`. Older builds drop unknown kinds, which is fine.
- `WorkspaceNavigationView`:
  - `routedDetail`, rail header, `defaultTitle`, scope picker
- Sidebar `WatchersNavigationButton` (clone `PRReviewNavigationButton`) with an unread-inbox badge
- Menu shortcut **⌘9**
- The agent-control allow-lists: `AgentControlRegistry`, `AgentControlController`, and the server's `control_cli`

Show the destination only when at least one roster machine reports `watchers-v1`. Otherwise show the PR Review-style "update the companion" empty state.

### 9.2 Files (modelled on `PRReview/`)
```
herdr-harness-mac/herdr-harness-mac/Watchers/
  WatchersClient.swift            protocol + HerdrAPIClient extension (+ timeout-table entries)
  WatchersModels.swift            DTOs (move to HerdrFirstMateShared/ only when iOS needs them, D10)
  WatchersStore.swift             @Observable, fleet-wide, generation guard; 30 s idle / 5 s while running; SSE-driven
  WatchersSummary.swift           chip markup parser → [SummaryRun] (text | chip), punctuation glue
  WatchersDemo.swift              synthetic watchers (the prototype's 12) for demo mode + render tests
  Views/WatchersView.swift        header, next-to-wake pill, filters, search, grid, resting divider, ask row
  Views/WatcherCard.swift         the V1 card
  Views/WatcherAvatar.swift       asset + state ring / z badge / attention dot
  Views/WatcherSummaryView.swift  flowing text with inline chips
  Views/WatcherChip.swift         the chip palette
  Views/WatcherRunsSheet.swift    run list + run detail (Cronboard RunDetailView, restyled)
  Views/WatcherBuilderSheet.swift chat + draft card + "How it runs" pipeline + footer
  Views/WatcherEditorSheet.swift  manual editor (Cronboard presets)
```

### 9.3 Mapping the prototype to SwiftUI
These are the V1 metrics (`avatars.css`), in points, with Herdr tokens for colors.

**Page**
- Padding 28 top, 30 sides.
- `h1` "A few extra pairs of eyes." at 28/medium, -0.9 tracking. Subtitle at 12.
- On the right, the "Next to wake up" pill: a 30 pt avatar, a two-line label and ▶. It jumps to that watcher; in the app it is not a clock skip.

**Filters:** All watchers (count), On watch, Resting, Scripts only, and search (`/` focuses it).

**Grid**
- `LazyVGrid` with 3 flexible columns, spacing 19 (25 at ≥1650 pt wide). Drop to 2 columns below about 950 pt and 1 below 650.
- Order: working, needs you, then by next fire. Resting watchers go under a divider.

**Card**
- Padding 15/24, radius 15, 1 pt outline at 5%.
- Fill: `cardFill` plus a top tint of the avatar tone at 4% over 150 pt. This one gradient is in V1 and was approved; the avatars themselves stay flat.
- Top row: status dot + word (On watch, Working now, Resting, Needs you, One-time task, Done) and an Edit button.
- Avatar 82 pt.
- Name 17/semibold, centred. Who line 10–11 pt: "**Sol** with scripts on Desktop" / "**Script** on Laptop".
- Summary at 12.5/line height ≈ 2.0, with chips (§9.4).
- "Next: *in 8 min*", using tone color for the time.
- "My last run needs attention." in rose when failed.
- Action row: Run now, Pause/Wake up, Past runs (count).
- **Working:** mint outline, the step label plus "Step 2 of 4", and a 3 pt progress bar.

**Ask row:** a dashed lavender row reading "What would you like someone to keep an eye on?" It opens the builder.

**Backdrop:** the app's standard pane glass (what the prototype's "Dusk glass" toggle shows), so the destination matches the rest of the window (D8).

### 9.4 Smart chips in SwiftUI
- **Parsing:** `WatchersSummary.parse(_ markup:)` turns markup into runs: words, and chips with any trailing punctuation glued on. `{time}` is filled from the schedule the server sends, `schedule.summary`.
- **Layout:** a custom `Layout` (flow layout) lays out word runs and chip views on shared baselines and wraps between words, never inside a chip.
  - Check for an existing flow layout in the app first.
  - Alternative: `Text` concatenation with inline images, but chips need rounded fills, so a `Layout` is simpler.
- **Chip:** 20 pt tall, radius 6, 11.5/semibold, a 12 pt icon, padding 4/6, and a 1 pt inner outline. Palette:
  - **time**: amber 11% fill / 30% line, text `#F2E0BC`
  - **skill**: lavender 13% / 32%, 🤖, text `#E2DFFF`
  - **agent**: lavender 7% with a mini face
  - **script**: mint 10% / 28%, monospace file name
  - **Slack** (brand mark), **GitHub** (mark), **inbox** (tray, accent), **repo/pc**: neutral `chipFill`
- **Accessibility:** each chip reads as "Slack channel agentic-monitoring", and so on. Check contrast over the brightest dusk point, using the `duskGlassContrast` test approach.

### 9.5 Avatars
- Export the 20 Original critters and 8 instruments from `v2-avatar-styles.js` as **flat SVGs** with a small Node script. Add them to `Assets.xcassets/WatcherAvatars/` with Preserve Vector Data on.
  - The renderer is deterministic, so this runs once.
  - The idle, resting (closed-eye) and working variants can be exported per avatar if the static set needs them.
- In SwiftUI, a disc or squircle is filled with the tone at 15% over the base, with a 1 pt ring at 16%. Overlays, all flat:
  - a working ring (mint, gently pulsing; respects Reduce Motion)
  - a "z" badge when resting
  - a rose "!" for needs you
- No animated eyes or moving instrument parts in v1 (D12).
- The library (Choose) is a grid of the same assets, with Characters for agent watchers and Instruments for script watchers.

### 9.6 Builder, editor, runs
- **Builder sheet:** 1080×740.
  - Left: the chat. Reuse First Mate chat primitives: `FirstMateFaceOrb` for Astra, message bubbles, chip markup in messages, and a tool-row list, plus a script file card.
  - Right: the draft as a V1 card, Shuffle/Choose, and "How it runs" (the pipeline from the prototype).
  - Footer: Dry run and **Create watcher** (sends `activate` with `confirmed_by:"user"`).
- **Editor:** name, machine, timezone, schedule presets (Cronboard `SchedulePreset` plus the server preview), the step list (add, reorder, edit script text, agent/model, skill picker from capabilities, Slack channel), missed-run and overlap policies.
- **Runs sheet:** outcomes with dots (mint finished, hollow nothing new, rose failed, grey stopped). Run detail shows steps, logs (last 128 KB, Cronboard's approach) and the agent response as Markdown (`HerdrProse`).

### 9.7 Updates and notifications
- `WatchersStore` subscribes to `watchers.*` SSE per machine. Add the events to the allow-list at `HerdrAPIClient.swift:2052-2058`, and handle them in `HerdrAppModel`.
- Run status changes refresh one card in place.
- New inbox items bump the sidebar badge and post a local notification, using the PR Review walkthrough pattern (`NotificationManager`).
- Calm-UI rule (`docs/macos-dashboard.md`): nothing ticks faster than once a minute, except the "in N min" label and live runs.

### 9.8 Tests
- **Contract tests:** `URLProtocol` stubs for every route; the 404/501 "update the companion" path.
- **Render tests:** grid (3 / 2 / 1 columns), every card state, chip wrapping and punctuation glue, the builder sheet with a draft, demo data only.
- **Unit tests:** summary parser, ordering, next-to-wake selection.

---

## 10. iOS (later)
- **Phase 6:** a read-only Watchers list and inbox on the iPhone, with APNs for "needs you".
- Move the DTOs, `WatchersClient` and `WatchersSummary` into `HerdrFirstMateShared/` at that point. That triggers iOS tests in local-verify.

## 11. Moving from Cronboard
- **Nothing is live to migrate:** 0 managed blocks and an old 1.0.0 install.
- `herdr-watchers import --crontab`:
  - reads the crontab with Cronboard's parsing rules (managed blocks plus 6-field external lines; it skips `@reboot` and environment lines);
  - creates **paused** script watchers with `cron` schedules and instrument avatars;
  - never edits the crontab;
  - prints the lines for you to remove once the watcher works.
- Retire the Cronboard app after the import (D3). Its repo stays as reference.

---

## 12. Phases

Each phase ships behind the `watchers-v1` capability and `HERDR_WATCHERS_ENABLED`, with synthetic fixtures and `check-public-source` passing.

### Phase 0: groundwork (small)
- Confirm the research claims you rely on, at the commit you build from.
- Port Cronboard's `CronExpression` tests to Python golden vectors. Add `*/n` and DST cases.
- Write the definition JSON Schema and the summary-markup validator with tests.
- Export the avatar SVGs (§9.5) to `design/watchers-2026-10-01/avatars/`.
- **Done when:** schema, validator and schedule tests pass, and the assets render.

### Phase 1: companion core, scripts only
- `watchers/store.py`, `schedule.py`, `runtime.py`, `runner.py`, `steps/script.py`, `steps/gate.py`, and inbox delivery.
- API: capabilities, list/get/create/patch/delete, actions (except `activate` from agents), runs, logs, inbox, schedule preview. SSE events.
- `herdr-watchers` CLI (everything but the builder and import).
- **Verification:**
  - unit tests for schedule, gate cursor and retention;
  - an integration test that runs a scheduler tick with a fake clock;
  - runner crash leads to `unknown`;
  - a server restart mid-run leads to reattach;
  - overlap `skip`; catch-up `run_once`;
  - Python CI shards green.

### Phase 2: agents and Slack
- `steps/agent.py`: Pi with skills from the runner, cost and session id, an untrusted-input charter.
- `steps/deliver.py` with the Slack `cli` and `api` adapters and the outbox semantics.
- `check` endpoints and CLI.
- **Verification:**
  - a fake `pi` binary and a fake Slack command in tests;
  - a delivery `unknown` state is never resent;
  - a gate cursor is committed only after delivery;
  - a 30-minute agent step survives a server restart.

### Phase 3: Mac destination
- Navigation (§9.1), `Watchers/` files, the grid and cards in the V1 + chips design, avatars, chips, Run now / Pause / Past runs, run detail, SSE updates, badge and notifications, demo mode.
- **Verification:** contract and render tests; local-verify "Mac tests (local)"; an on-screen check over real dusk glass (offscreen renders can't show it, per the Mono UI lesson).

### Phase 4: the AI builder
- `watcher-builder-v1` profile and charter, builder session routes and events, the Mac builder sheet, Shuffle/Choose, dry run, Create watcher (human-confirmed activate), Edit with Astra.
- Pi discovery extension and docs, so the First Mate lead can draft from chat.
- **Verification:** scripted builder conversations against a fake Pi; the prototype's three example prompts produce valid drafts; the agent cannot activate.

### Phase 5: editor, import, polish
- Manual editor, crontab import, retention job, missed-run and overlap controls in the UI, fleet aggregation edge cases (machine offline, mixed versions), Dashboard section ("Watchers that need you"), the avatar library sheet.

### Phase 6: iPhone (optional)
- See §10.

### Releases
- Ship the companion package first, everywhere: allow-list `watchers` and keep the feature off by default.
- Then enable per machine through `[machines.<id>.environment] HERDR_WATCHERS_ENABLED=1`.
- Then ship the Mac app through the signed feed (`docs/macos-releases.md`), gated on `watchers-v1`.
- Update the README feature table, `release/notes/companion-next.md` and `macos-next.md`, and add a `herdr-docs` topic.
- **Publishing and enabling are separate, explicit steps.**

---

## 13. Risks

| Risk | Mitigation |
|---|---|
| Shared config allow-list breaks older companions | Two-step rollout (§5.7) |
| Agent steps die on companion updates | Detached runners and reattach (§3, §5.2) |
| Laptops sleep, so runs are missed | `missed_runs` policy, plus host frequent watchers on the devbox (D2) |
| Double-posting to Slack | Outbox with an `unknown` state and no automatic resend; commit gate cursors after delivery |
| Agent schedules work unattended | Drafts only; `activate` needs a user click; no activate in agent discovery |
| Untrusted fetched content steers an agent | Fenced input, ask-mode tools by default, charter rules |
| Secrets leak into definitions or logs | Adapters read private config; scrub outbound text; no tokens in scripts |
| launchd PATH: no login shell | Explicit PATH in config; CLI wrappers on the agent PATH |
| Two agent slots shared with HUD chats | A separate watcher agent-step pool |
| Name collisions ("watchers", "inbox") | Namespaced modules (`herdr_harness/watchers/`); "Watcher inbox" in the UI |
| Unbounded history (Cronboard's flaw) | Retention from Phase 1 |
| Cron day-field semantics | Fix `*/n`; golden tests |

---

## 14. Open decisions (defaults in bold)

- **D1. Scheduler home:** **companion scheduler thread plus detached runners**; a separate LaunchAgent daemon; or keep the crontab.
- **D2. Default host machine:** **the machine you build from, suggesting the devbox for anything hourly or more frequent**; or always the devbox.
- **D3. Cronboard:** **retire it after `import --crontab`**; or keep it as a standalone app.
- **D4. Inbox:** **a separate "Watcher inbox"**; or merge into the Work Inbox.
- **D5. Missed runs:** **skip for intervals of an hour or less, run once for daily and weekly**; or always skip.
- **D6. Activation:** **a user click only**; or allow the agent to activate after an explicit "yes" in chat.
- **D7. Who can build:** **the builder sheet, plus drafts from the First Mate lead**; or the builder sheet only.
- **D8. Backdrop:** **the app's pane glass**; or V1's flat dark.
- **D9. Agent tools:** **ask mode (read-only) by default, with act mode opt-in per watcher**.
- **D10. Shared models:** **Mac-only until the iPhone phase**; or shared from day one.
- **D11. Retention:** **30 days or 200 runs per watcher; inbox 90 days**.
- **D12. Avatar motion:** **static assets plus state overlays**; or animated eyes and instruments later.
- **D13. Slack adapter:** **your existing Slack CLI**; or a bot token with `chat.postMessage`.
- **D14. Script exit for "nothing new":** **75 (`EX_TEMPFAIL`)**; or a JSON flag in `HERDR_WATCHER_OUTPUT`.

---

## Appendix A. Prototype files that matter

**Card, grid and builder layout**
- `design/watchers-prototype/avatars-v1-chips.html`, with V1's `avatars.css` and `common.css`.

**`v2-core.js`**
- `says()`: chip rendering
- `readSchedule`/`readFacts`/`build`/`refine`: the builder's local stand-in parser. It describes the intended behaviour; it is not production logic.
- `pipeline()`: the "How it runs" list
- `seed()`: synthetic demo watchers

**`v2-avatar-styles.js`**
- The Original critters, with the six V1 drawings kept as they were.
- The instrument kit used for script watchers.

## Appendix B. Reference commits
- herdr-companion `origin/main` `eac13aa` (2026-10-01). The local checkout was 197 commits behind and had unrelated uncommitted work, so the research used a clean export.
- Cronboard `main` `15b6863`, version 1.2.3; 1.0.0 is installed.

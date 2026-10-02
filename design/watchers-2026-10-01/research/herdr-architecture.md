# Herdr companion: where Watchers fits (layer 1, 2026-10-01)

> Read-only sweep of a clean export of `origin/main` at **`eac13aa`** (2026-10-01). Paths are relative to the repo root.
> Labels: **confirmed in code** unless marked *inferred*. Spot-checked in the main session:
> - the config section allow-list (`config.py:340`)
> - `--no-skills` in headless runs (`agent_runs.py:1425,1450`; `code_factory/pi.py:171`)
> - agent-run limits (`agent_runs.py:511-523`)
> - `AgentRunManager.stop` cancelling runs (`agent_runs.py:2050+`)

Two facts shape the whole plan:
- **There is no generic scheduler or cron anywhere.** Periodic work today is internal service loops plus operator-scheduled external CLIs.
- **`herdr-pr-review-watch` is already a hard-coded watcher** (§9). It runs a deterministic poll, checks whether items are new, sends the new ones to a headless `pi` step, and delivers the results to a board.

## 1. Server (`herdr_harness/`)

**Framework and startup**
- Standard library only. The server is `ThreadingHTTPServer` (`server.py:3492-3514`).
- `herdr-server` maps to `herdr_dashboard.py:main`, which does the following in order:
  - loads the config,
  - requires `HERDR_HARNESS_API_TOKEN` unless running loopback-insecure,
  - builds `HerdrClient` (the Herdr NDJSON socket) and `HerdrService` (`service.py:110`),
  - starts the HTTP server, then `service.start()`.
- Subsystems are lazy properties on `HerdrService`: First Mate (`:636-657`), PR Review (`:671-681`), simulator previews (`:697-705`), First Mate notifications (`:707-713`), agent runs (`:715-727`).

**Routing**
- `_dispatch` (`server.py:886-1001`) handles static pages, requires the `api/v1` prefix, checks auth, applies per-route body limits, then calls `_route`.
- `_route` (`:2012-2031`) is an `if` chain. It delegates to `_control_route`, `_first_mate_route` and `_pr_review_route`.
- Validation conventions:
  - exact body-key sets
  - the `_string`, `_identifier` and `_query_int` helpers (`:239-430`)
  - `request_id` for idempotency
- Responses are `{"ok": true, …}` or `{"ok": false, "error": {code, message}, "generatedAt"}`. Each subsystem's exception class is mapped in `_dispatch`.

**Versioning and discovery**
- There is one prefix, `/api/v1`. Features are announced as capability strings in `api_description()` (`server.py:447-661`, served at `GET /api/v1`), along with `endpoints`, `mutations` and `sseEvents`.
- Each subsystem also has its own `/capabilities` route, e.g. First Mate at `:1249`.

**Auth**
- Bearer tokens are compared with `hmac.compare_digest` (`:772-829`). The main token is `HERDR_HARNESS_API_TOKEN`.
- Some routes require main scope, e.g. agent profiles (`:2036-2038`).

**Persistence**
- The state root is `HERDR_STATE_DIR`, default `~/.local/share/herdr-companion` (`config.py:425`).
- Per-subsystem SQLite paths are derived at `config.py:430-446`.
- Store conventions, using `FirstMateStore` (`first_mate_store.py:362-510`) as the model:
  - files are 0600, WAL mode, `busy_timeout`
  - additive migrations through `PRAGMA table_info`
  - an idempotency receipts table, which returns `idempotency_conflict` when a `request_id` is reused with different content

**Background loops** (`service.py:487-546`)
- the Herdr event and snapshot threads
- Pi semantic bridge and remote activity
- unread notifications (1 s)
- the First Mate runtime (0.25 s) and guardian (10 s), plus an hourly reliability sweep
- First Mate notifications (2 s)
- PR Review runtime (2 s), which uses a `manager.lock` flock so only one scheduler runs per state directory (`pr_review_runtime.py:164-176`)
- the agent-run reaper

**External daemons:** `herdr-code-factory run` runs as a KeepAlive LaunchAgent with a `DaemonLock` (`docs/code-factory.md:231-270`). The operator schedules `herdr-pr-review-watch` and `herdr-active-work-sync` separately. First Mate's docs say it "does not use cron" (`docs/first-mate/reliability.md:6`).

**Config**
- One shared private TOML, with per-machine overrides in `[machines.<id>]` (`config.py:312-447`).
- Secrets are written as `{env=…}` or `{file=…}`. `[environment]` is an escape hatch for any env var.
- **Top-level sections are allow-listed (`config.py:340`).** A new `[watchers]` table is a hard error for older companions that read the same file.
- `[integrations]` already exists (GitHub repo, Jira, review model).

## 2. Agents and sessions

There are five ways to run an agent today.

**a) Headless one-shot runs: `AgentRunManager`**
- Flow: `POST /api/v1/agent-runs` → `_execute` (`agent_runs.py:1266-1663`).
- Command: `pi -p --mode json … --no-skills …`, with the prompt on stdin. The result is the run's `status` plus `response`.
- Limits:
  - **2 concurrent slots** shared with HUD chats (`:511-513`)
  - 1 h timeout
  - 1-day TTL for non-HUD runs
  - **runs are cancelled when the service stops** (`:2050+`)
- The `hud-chat-v1` profile keeps normal Pi discovery, **including skills** (`:1444-1453`).

**b) Synchronous `PiRunner`** (`code_factory/pi.py:112-200`)
- Returns `PiResult(text, exit_code, cost_usd, session_id, …)`.
- Kills the process group on timeout and scrubs tokens from the environment.
- Hard-codes `--no-skills` (`:171`).

**c) A visible Pi chat in a pane (Quick Voice pattern)**
- `quick_pi_session`, then a `pi_command prompt`, then `settled_result()` (`quick_voice.py`).

**d) PR Review skill runs in panes**
- Runs `agent.start` in a split pane; `/<skill>` is rewritten to `/skill:<id>` for Pi (`pr_review_runtime.py:589-596`).

**e) First Mate managed sessions**
- Each is a detached runner process, `python -m herdr_harness.first_mate_runtime --runner <jobdir>`, using Pi RPC mode with role charters.
- **They survive companion restarts** by reattaching through per-job locks (`docs/first-mate/runtime.md:20-30`).

**Models**
- "Astra/Sol/Luna" are only Pi `provider/model` ids, with display names in `Models/PiModelDisplayName.swift`.
- Role routing is configured in `[first_mate]` and resolved by `first_mate_routing.resolve_dispatch_policy`.
- Model catalogs: `GET /agent-runs/models` and `GET /first-mate/models`.

**Lead and remote routing**
- The lead First Mate is one per companion, with a closed tool set (`LEAD_TOOLS`; `first-mate.ts`; `_lead_tool`).
- `fm_relay` and `fm_create_feature` are allowed only on the human's own turn.
- Peers are reached with `POST /first-mate/lead/remote`, using each machine's credential.

**Is there a reusable "run a prompt, get the result" call?** Yes: `POST /agent-runs` (polled), or `PiRunner.run(...)` in process. **Neither runs skills today**, so a watcher step needs a skills-enabled profile, a `/skill:<name>` prompt prefix, and its own durable ledger.

## 3. Skills

- `GET /workspaces/{id}/skills` scans only `<project>/.claude/skills` and `~/.claude/skills` (`workspace_tools.py:361-405`).
- Fleet inventory lists catalog skills installed to `~/.agents/skills`.
- **No API lists Pi-global skills on a machine.**
- To use a skill, put `/skill:<name> …` in the prompt with skills discovery on.

## 4. CLIs

**Console scripts** (`pyproject.toml:18-34`): `herdr-server`, `herdr-config`, `herdr-control`, `herdr-docs`, `herdr-profiles`, `herdr-first-mate`, `herdr-pr-review`, `herdr-notes`, `herdr-hud-chats`, `herdr-session-context`, `herdr-active-work`, `herdr-code-factory`, `herdr-active-work-sync`, `herdr-pr-review-watch`, `herdr-prune-runtimes`, `herdr-demo`.

**API-client CLI pattern**
- `herdr_harness/commands.py` loads the config, then calls `herdr_commands.<module>.main`.
- Clients enforce HTTPS, or HTTP on loopback only, and reject redirects.
- Output is JSON on stdout. Errors are JSON on stderr; exit code 2 for errors and 4 on 409. Tokens are redacted.
- Example: `scripts/herdr_first_mate_cli.py:43-201`, which pre-checks capabilities.

**`herdr-control`** reaches any roster machine with that machine's credential (`control_cli.py:574-633`).

**How agents learn about CLIs**
- Pi extensions such as `notes-discovery.ts` inject instructions. They activate only with `HERDR_PANE_ID` or `HERDR_AGENT_RUN_ID` set, so **not for the First Mate lead**, which runs with `HERDR_FIRST_MATE_MANAGED_ROLE`.
- `agent-docs/overview.md` and `herdr-docs` topics.

## 5. Inbox, notifications, Slack

- **There is no Slack integration.**
- **The Message Hub outbox** (`first_mate_notifications.py:30-162`) is the template for delivery:
  - a per-feature cursor and a deliveries table;
  - a send that is in flight at restart becomes `unknown`, and automatic resends are suppressed;
  - every outcome is written back to the journal.
- **APNs** (`push_notifications.py`) and alerts with read state (`alerts.py`).
- **The Work Inbox already exists** (`GET /work-inbox`, Mac `WorkInboxStore`): GitHub review requests and Jira. **This is a naming collision.**
- **SSE:** an `EventBroker` ring at `GET /api/v1/events`. The Mac consumes events per machine (`HerdrAppModel.swift:5450-5500`) through a parser allow-list (`HerdrAPIClient.swift:2052-2058`). For example, the PR Review walkthrough event triggers a badge and a local notification.

## 6. Mac app

**Scenes and shortcuts:** `App/HerdrHarnessMacApp.swift`. ⌘1–⌘8 are taken (PR Review is ⌘8), so **⌘9 is free**.

**Navigation**
- `HerdrDetailScope` and `HerdrShellState` (`Views/Root/AppRootView.swift:7-759`).
- `HerdrDestination` (`Models/NavigationHistory.swift:11-33`) uses persisted string kinds, so an older build drops unknown ones.
- Detail routing is in `Views/Workspace/WorkspaceNavigationView.swift`: `routedDetail`, the rail header, title and scope picker.

**Sidebar:** `Views/Sidebar/HerdrSidebarView.swift:237-260` has the Dashboard, First Mate and PR Review buttons. Clone `PRReviewNavigationButton.swift` (which already has a badge) for Watchers.

**Agent-control allow-lists:** `AgentControlRegistry.swift:24`, `AgentControlController.swift:1078`, and server `control_cli.py:1638,1643`.

**Feature template, PR Review:** `PRReview/PRReviewClient.swift`, `PRReviewModels.swift`, `PRReviewStore.swift` (`@Observable`, generation guard, 5 s busy / 30 s idle polling, 404/501 treated as "update the companion"), `PRReviewDemo.swift`, `Views/*`.

**API client:** `Infrastructure/HerdrAPIClient.swift` is an `actor` with a per-path timeout table (default 15 s).

**Design system**
- `Design/HerdrTheme.swift`, `HerdrRecipes.swift` ("flat fill plus at most one 1 pt line"), `HerdrGlass.swift`.
- Avatar primitives: `FirstMateEmojiDisc` and `FirstMateFaceOrb` (`FirstMate/ChatWindow/FirstMateChatPrimitives.swift`).

**Project and tests**
- The project uses synchronized folders, so new files join targets automatically.
- Tests use Swift Testing. Render tests use `HerdrRenderHarness` and `$HERDR_RENDER_DIR`; contract tests stub `URLProtocol`. UI tests run in demo mode.

## 7. iOS and shared code

- `HerdrFirstMateShared/` is compiled into both apps. Put Watchers DTOs and a `WatchersClient` protocol there **if the iPhone will show watchers**.
- Changes there trigger iOS tests in local-verify (`scripts/verification_policy.py:22`).

## 8. Contract, compatibility and release

**Rules**
- One shared contract across the server, apps, web and Pi extensions.
- Fields are additive, `request_id` replay rules apply, and features are gated on capabilities (`docs/first-mate/build-contract.md`).
- Synthetic fixtures only, enforced by `check-public-source`.
- Keep the README feature table and release notes current.

**Template for a new optional subsystem:** `release/notes/companion-next.md` (simulator previews). It follows this pattern:
- a new capability, inert until configured
- new routes
- an idempotent outbox
- its own SQLite file

**Release**
- Mac: Sparkle feed via `scripts/release-macos.py`. The companion wheel is published separately (`0.71.0b1` at this commit).
- Verify CI runs Python test shards, the web and Pi bridge tests, and a privacy job.
- `scripts/local-verify.py` posts the "Mac tests (local)" status.

## 9. Existing watcher, cron and schedule names

**`scripts/herdr_pr_review_watch.py`** is effectively a hard-coded watcher:
- runs with `--once` or `--loop SECONDS`, under a stale-able lock;
- step 1, deterministic: the `gh` queue;
- gate: compares against existing board item IDs;
- agent step: `pi --no-session -p --model … --append-system-prompt agent.md @task`, parsing an `ASSESSMENT_JSON:` line;
- delivery: writes to the Active Work board via its CLI.

**Name collisions:** `pi_semantic.py` has `_watchers` (per-pane bridge threads), and `simulator_previews.py` / `FirstMateSimulatorModels.swift` use `watchers` to count stream viewers.

**`workflows.py`** holds versioned JSON stage templates. They are a good model for validating watcher definitions.

## 10. Natural seams and main risks

**Seams**
- **Store and runtime:** `herdr_harness/watchers_store.py` and `watchers_runtime.py`, as a lazy `HerdrService` property started in `start()`, guarded by a `manager.lock`, inert until configured.
- **API:** a `_watchers_route` branch in `_route`, main scope only, plus a `watchers-v1` capability and SSE events.
- **CLI:** `herdr-watchers` → `herdr_harness.commands:watchers` → `scripts/herdr_watchers_cli.py`.
- **Agent discovery:** a discovery Pi extension that also activates for the First Mate lead.
- **Mac:** a `HerdrDetailScope.watchers` case wired through every switch, a sidebar row with a badge, ⌘9, and a `Watchers/` folder modelled on `PRReview/`.

**Risks**
1. The config allow-list (`[watchers]` would break older companions).
2. Durability: agent runs are cancelled on restart.
3. Capacity: two agent slots shared with HUD chats; 1-day TTL.
4. Skills: disabled in headless runs, and no Pi-global skills API.
5. Authority: unattended scripts and agents run as the operator, and chat creation needs explicit human confirmation. Fetched content is untrusted.
6. Slack credentials and at-most-once delivery.
7. Multiple machines: per-companion stores, and Macs sleep.
8. launchd environment: no login shell, and the companion CLIs are not on the agent PATH by default.
9. Naming collisions (watchers, inbox).
10. Process overhead: changes to the shared folder trigger iOS tests, the Mac UI must be gated on `watchers-v1`, and fixtures must be synthetic.

# Herdr Companion agent overview

Herdr Companion is the companion application and local server for the upstream
Herdr terminal. Pi is the agent runtime. They are separate components: the
terminal owns workspaces, tabs, panes, and processes; Pi owns agent sessions and
tools; Companion projects those sessions and selected terminal state into native
Mac/iPhone/iPad and browser clients.

A conversation can be:

- a Pi chat in a Herdr-managed workspace pane;
- an independent saved HUD chat, outside terminal workspaces;
- a bounded Companion agent run in ASK or ACT mode; or
- a First Mate feature conversation or tracked assignment.

Do not infer which client is frontmost, which machine stores data, or whether an
optional capability is enabled from a display label. Clients differ, and the Mac
app, companion server, Pi package, and upstream Herdr may be upgraded separately.
Read live capability/action catalogs before promising support.

## When to use these references

Read this topic when asked “what app am I in?”, “what can Herdr control?”, “can
you manage this in the app?”, or how Herdr, Pi, and Companion relate. Then read:

- [`control`](control.md) for CLI discovery and typed app/resource actions;
- [`first-mate`](first-mate.md) for tracked feature workflow and scoped self-management;
- [`api`](api.md) for the authenticated Companion API map.

Use `herdr-docs list`, `herdr-docs read TOPIC`, or `herdr-docs path TOPIC`.
These commands are offline and read the installed reference set. For exact live
syntax, run the relevant installed CLI with `--help`; for control operations,
query the advertised action and capability catalogs.

## Installed CLI index

- `herdr-control`: fleet discovery, exact target inspection, typed resource/UI
  actions, and receipts;
- `herdr-first-mate`: external feature inspection and operator lifecycle actions;
- `herdr-notes`: synchronized note list/search/read and revisioned mutations;
- `herdr-active-work`: items, ticket paths, stage evidence, and durable handoff;
- `herdr-hud-chats`: saved HUD history discovery (`list`, `search`, `show`);
- `herdr-session-context`: projected prior conversation by exact identity;
- `herdr-pr-review`: PR Review resources and native navigation;
- `herdr-config`: configuration checks and selected-machine execution setup;
- `herdr-code-factory`: an optional, explicitly configured issue-to-PR/release
  pipeline. It does nothing merely because the CLI is installed. Enabling it,
  enqueueing work, GitHub mutations, merges, and releases remain external
  operator-authorized actions subject to its allowlists, labels, CI, privacy,
  signing, and human gates.

Discovery is not authorization. Preserve the user’s current scope, human
checkpoints, ASK/no-tool restrictions, project trust, and credential boundaries.
Never place credentials in command arguments or output.

## Version skew and reload

A native app update does not install the companion server or Pi package. Upgrade
components separately using the release’s compatibility notes. New Pi sessions
load an updated installed package automatically. For a running session using the
global package, use `/reload` while idle. A session launched with an explicit old
`-e`/`--extension` path must be safely exited and resumed without that stale
override; `/reload` retains launch-time paths.

Developer-only, nonessential source references include the repository `README.md`
and `docs/`. Installed operation must not depend on a source checkout.

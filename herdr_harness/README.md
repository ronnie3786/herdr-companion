# Herdr companion server

The standalone server serves native apps and a web client through an authenticated
`/api/v1` API and server-sent event streams. It connects to the separately installed
Herdr terminal using its local socket API.

Start with the repository [README](../README.md) and
[configuration example](../config.example.toml). `herdr-server` and the installed
Herdr CLIs read the same private TOML, with shared and per-machine settings.

The server owns Git operations, local files/skills, attachments, notes, Pi
semantics, headless runs, result artifacts, Active Work, Fleet, cleanup, and optional
voice/push providers. GitHub and Jira use configured local CLIs. Models and speech
providers have no private defaults.

`herdr-notes --help` and `herdr-active-work --help` describe the agent commands.
They support `--config` and `--machine`, respect token scopes, reject redirects,
and report concurrent-edit conflicts. Optional sync/review commands need explicit
integration configuration. Release packages include board/web assets and Pi
extensions, without needing another source checkout or orchestration service.

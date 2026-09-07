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

## Update the server

Use a tested source revision compatible with the native apps you intend to keep.
Build fresh web assets before the release wheel:

```sh
npm --prefix frontend/herdr-web ci --ignore-scripts
npm --prefix frontend/herdr-web run build
.venv/bin/python -m build --wheel
```

Install the exact resulting wheel into a new Python 3.11+ virtual environment;
record its source revision and SHA-256. On macOS, keep installed runtimes outside
protected Documents/Desktop/Downloads folders, for example under
`~/Library/Application Support/Herdr/Backend/<revision>/`. A checkout update alone
does not update an installed runtime. Keep your existing private TOML and state
paths, including Fleet ownership/quarantine records and referenced attachments.

Set `runtime_python` below to the new environment's absolute Python path. Run the
packaged-install smoke test from the matching source checkout; it starts a temporary
server with isolated state, then shuts it down:

```sh
runtime_python="/absolute/path/to/new/runtime/bin/python"
.venv/bin/python scripts/verify-installed.py --python "$runtime_python"
```

Before switching services, use that interpreter to validate the real configuration
and Fleet paths. Replace `desktop` with the selected machine ID. This check resolves
configured credentials without printing them and does not install Fleet items or
start a server:

```sh
"$runtime_python" -I - "$HOME/.config/herdr-companion/config.toml" desktop <<'PYCODE'
import sys
from herdr_harness.config import load_configuration
from herdr_harness.fleet import FleetManager
config = load_configuration(sys.argv[1], sys.argv[2])
FleetManager(environ=config.environ)
print("Configuration and Fleet paths are valid.")
PYCODE
```

`herdr-config check --config /path/to/cluster.toml --machine desktop` validates the
shared configuration alone. Fleet construction additionally checks destination
names, overlaps, and path constraints. The built-in `agents` destination already
uses `~/.agents/skills`; only additional destinations belong in
`[fleet.skill_destinations]`.

If you enable workers that read local folders, verify directory enumeration with
the new interpreter under the intended launcher identity before completing the
update. Buzz sync reads `tickets/*/state.json` beneath `active_work.workflow_root`.
On macOS, a background process can wait for a Documents-folder permission prompt
even when an SSH shell can read that folder. Resolve the OS permission request and
verify the worker completes; changing the code's location does not grant access to
protected data folders. Keep the configured data paths intact.

Take a consistent state backup, then switch the companion service to the new
runtime's `herdr-server` with explicit `--config` and `--machine` arguments. Keep
the separately installed upstream Herdr terminal service running. For launchd,
use absolute executable/configuration paths; it does not expand `~`. If the TOML
sets `PATH`, `/usr/bin/env -u PATH` before the installed command lets that value
apply instead of an inherited default.

Update wrappers or service definitions for `herdr-notes`, `herdr-active-work`, and
any enabled `herdr-active-work-sync` or `herdr-pr-review-watch` jobs to the same
runtime. Preserve the workers' existing schedule and flags, and give each the same
explicit configuration and machine selection. Replace only the matching Herdr
entry in Pi's package settings, preserving other packages. Resolve its installed
extension directory with:

```sh
"$runtime_python" -I -c 'from herdr_harness.resources import pi_extension_path; print(pi_extension_path({}))'
```

Verify authenticated health, terminal connectivity, web assets, saved notes/board
state, Fleet, and Pi integration. Check each enabled worker separately for a
completed successful run; a healthy HTTP server does not prove its workers can
read their inputs. Keep the previous runtime and service definitions until these
checks pass. If the update fails, restore those definitions and the prior runtime,
preserving current data unless a documented state migration requires restoring a
consistent backup. A server-only update does not require replacing the Mac app.

# Companion 0.34.0b1

This server release adds an independently pinned **Architect** role to First Mate. Architecture/design reviews and implementation second opinions use that role without requiring the human to name a stage or model profile. Existing planning, execution, coordinator, and watchdog-advisor routing remain unchanged.

## Configuration

Set an exact provider-qualified model and optional thinking effort in private host configuration:

```toml
[machines.desktop.first_mate]
architect_model = "your-provider/your-architect-model"
architect_thinking = "high"
```

Equivalent environment settings are `HERDR_FIRST_MATE_ARCHITECT_MODEL` and `HERDR_FIRST_MATE_ARCHITECT_THINKING`. Shared settings and per-machine overrides follow the existing configuration precedence. No operator model choice is embedded in this package.

Architect assignments cannot override the host pin or fall back to a planner, worker, or Pi default. Missing configuration fails visibly. Before sending an architect task, the supervisor verifies Pi's observed model and configured effort; a mismatch or missing observation stops the dispatch. Requested policy and actual observations are retained separately in assignment/session details and the CLI/browser API.

## Installation and compatibility

Install the wheel into a new versioned Python 3.11+ runtime and follow the [server update procedure](https://github.com/ronnie3786/herdr-companion/blob/companion-v0.34.0-beta.1/herdr_harness/README.md#update-the-server). Update matching CLIs and the bundled Pi package together. Validate private configuration, take consistent state backups, and retain prior runtime/service definitions for rollback before switching the companion service.

A checkout update or Mac self-update does not deploy this package. Do not replace the separately installed terminal service. Running First Mate workers retain their original dispatch policy; new dispatches, retries, and continuations use current host settings. Existing clients safely ignore additive fields; the 0.34.0 Mac preview adds architect policy visibility and expanded requested-versus-actual details. No iOS binary is published here.

# Agent awareness and installed references

Herdr Companion gives its managed Pi agents a small, per-turn identity and an
installed reference index. The bootstrap says which kind of Companion session is
running and where to read more; it does not inject the guide bodies, inspect user
data, expand tool authority, or claim which client is frontmost.

## Coverage

| Runtime | Identity |
| --- | --- |
| Pi in a Herdr pane | Managed workspace chat, viewable through native/browser clients |
| Saved HUD chat | Independent saved conversation outside terminal workspaces |
| Ordinary ASK/ACT run | Companion agent run; its existing mode charter remains authoritative |
| First Mate coordinator/worker/advisor | Validated role plus bounded feature/job and applicable assignment identity |
| External/unmanaged Pi | No Companion identity from package installation alone |

Contextual questions, PR Review questions, response briefs, and Smart Rename keep
their existing restricted profiles. They do not receive the awareness bootstrap,
extra tools, or reference invitation. First Mate injection occurs only after the
managed role, private job, and selected extension path validate; stale or foreign
copies remain dormant.

Useful trigger questions include “What app am I in?”, “What can Companion do?”,
“Can you open/manage this in the app?”, and “How should this First Mate feature be
run?” The agent is directed to read only the relevant guide, then run current CLI
help and live capability/action catalogs rather than infer support.

## Offline reference commands

The companion wheel installs a closed, read-only reference set:

```sh
herdr-docs list
herdr-docs read overview
herdr-docs read control
herdr-docs read first-mate
herdr-docs read api
herdr-docs path overview
```

These commands require no configuration, token, network, source checkout, or Pi
override. Unknown names and path traversal are rejected. Absolute paths point
inside the installed wheel resources (or the source tree during development).

The references distinguish upstream Herdr, Pi, and Companion; summarize supported
native/browser surfaces; index control and First Mate workflows; and map API
families. The live server and CLI catalogs remain authoritative. Discovery never
authorizes a mutation or bypasses project trust, ASK/no-tool policy, workflow
scope, credential handling, or a human checkpoint.

## Rollout and version skew

The native apps, companion server/wheel, Pi package, and upstream terminal update
separately. Install the matching companion wheel on each server host so
`herdr-docs`, server-launched fallback context, bundled guides, and Pi extension
agree. A Mac updater release does not install that wheel.

New Pi sessions load the current globally installed package. For an idle running
session that uses global package discovery, use `/reload`. If the session was
started with an explicit old `-e`/`--extension` path, safely exit it and resume
without that old override; `/reload` preserves launch-time extension paths and
may otherwise keep duplicate/stale behavior. Do not interrupt running agents only
to roll out awareness.

If bundled guides are missing, ordinary run startup continues without advertising
a nonexistent path. Reinstall the wheel/package before relying on discovery.

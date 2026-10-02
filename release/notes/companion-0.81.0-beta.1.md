# Companion 0.81.0-beta.1

Removes the response brief API, which Mac 0.97.0-beta.1 no longer uses (skims replace it).

- `response-brief-v1` is gone from `/api/v1/agent-runs/capabilities`, with its `responseBriefs` block and the bundled lineage extension.
- `POST /api/v1/agent-runs` rejects that profile with the normal unsupported-profile error (400).
- It also rejects the `parentSessionId` and `responseBriefLength` fields.
- Brief runs saved by earlier versions stay readable in run history until they expire. Continuing or promoting one returns 409 `agent_run_profile_retired`.
- Older Mac apps detect the missing capability and show their update notice instead of requesting briefs.

Agent control matches the Mac app's new title bar:

- `herdr-control ui segment` no longer offers `workspace` or `attention`.
- Workspace and tab discovery records advertise no open mode.
- `ui open` on a workspace or tab fails with `unsupported_target` against Mac 0.97.0 and enqueues nothing; older Macs still accept those targets.
- `workspace create`, `tab create`, renames and tab colors are unchanged.

Other server, web, iOS and Pi package behaviour is unchanged. Install the wheel in a new versioned runtime using the server update procedure in `herdr_harness/README.md`. Preserve private configuration and back up state before upgrading. Update matching CLI/Pi components and restart affected services only after active work is safe. The Mac updater does not install this package or restart companions.

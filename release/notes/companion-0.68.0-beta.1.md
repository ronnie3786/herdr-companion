# Companion 0.68.0b1

This companion release adds First Mate simulator checkpoints through SimPortal and
carries forward everything in 0.67.1b1.

- Adds `first-mate-simulator-previews-v1`. First Mate workers and coordinators get an
  `fm_register_simulator_build` tool that saves a compiled iOS Simulator `.app` as a
  checkpoint in SimPortal on the same machine. The companion records the feature,
  stage, assignment, and session itself. Saving a build is never verification
  evidence.
- New routes under `/api/v1/first-mate`: `GET /simulator`, a feature's
  `simulator-builds`, `POST …/simulator-builds/{build_id}/preview` (reuse the running
  simulator or start one), preview detail and `POST …/stop`, and a WebSocket relay for
  that preview's exact simulator. The relay never changes SimPortal's shared focus.
- Every SimPortal mutation is persisted with its request ID and replayed unchanged, so
  a lost response never creates a second build or simulator.
- Resource policy: up to `max_running_previews` (default 4) Herdr simulators run per
  machine, and opening one more shuts down the least recently watched idle one. A
  simulator nobody has watched for `idle_shutdown_minutes` (default 60) is shut down.
  Only this companion's own previews are ever stopped, and none are ever deleted.
- A preview whose simulator was deleted on SimPortal's Machines page reports phase
  `stopped` with status `simulator_deleted`.

The feature stays off until the private configuration has a `[simportal]` section
(`url`, `token_file`, `intake_root`; see `config.example.toml`). Add it only after
installing this package: older companions reject the unknown section. SimPortal must
run on the machine that compiles the builds, with enough free disk for its admission
floor (20 GB by default). See
[simulator checkpoints](https://github.com/ronnie3786/herdr-companion/blob/main/docs/first-mate/simulator-previews.md).

Install the companion server package and its Pi extension separately on each machine
that runs First Mate. The Mac app updater does not install or restart companion server
packages.

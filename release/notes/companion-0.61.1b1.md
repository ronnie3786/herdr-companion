# Herdr Companion server 0.61.1b1

Fewer First Mate features stop for your inspection when a worker is interrupted,
and workers are no longer stopped while they write their handoff.

- **Handoff grace.** A handoff request (from the context target or an advisor)
  now allows three minutes to reach a safe boundary and call `fm_handoff`, up from
  a fixed 90 seconds. Past that the worker keeps its turn while Pi still reports
  activity (thinking, text, or a tool call streaming or running within the last
  minute), and is stopped only once it goes quiet or 15 minutes after the request.
  In the last week the old deadline stopped 20 workers, several mid-way through
  writing the checkpoint, which lost the checkpoint, its verification and its
  outcome together.
- **Recovery asks you only about effects beyond this machine.** A failed or
  unfinished call blocks automatic recovery only when it may have reached beyond
  this machine: a push, release, upload, deploy, remote API call, remote shell,
  message, agent CLI, a non-shell tool other than `edit`/`write`, or a truncated
  command. Local failures (a red test run, a build, a diff that found
  differences, an edit whose text was not found, a command cut off mid-run) are
  journaled as `reliability.local_effects_noted` and listed as
  `local_commands_to_check` in the recovery checkpoint for the advisor and the
  successor to check first. None of last week's sixteen "interrupted or failed
  side-effecting tool" blocks involved anything beyond the machine.
- Nothing is replayed: a successor still inspects and acknowledges the retained
  checkpoint before changing anything, and a blocker that already exists stays
  until you recover it.

## Install separately

Use the server update procedure in `herdr_harness/README.md`. Build/install in a
new Python 3.11+ runtime, preserve private configuration, take a consistent state
backup, validate the package and configuration, then explicitly switch the
companion and matching CLI/Pi integration. There is no database or API change.

The signed Mac updater installs only the app. Publishing this package performs no
server cutover and no iOS installation.

## Verify

Check `docs/first-mate/reliability.md` ("Safe effects and ownership") and
`docs/first-mate/runtime.md` ("Worker activity and context handoff"). A worker
that is asked to hand off while it is still producing output now finishes its
`fm_handoff` instead of being stopped at 90 seconds.

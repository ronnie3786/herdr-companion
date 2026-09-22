# Companion 0.33.0b1

This package adds contextual agent awareness and offline reference documentation for Herdr Companion. It retains the reviewed First Mate Git and Code Factory changes included in the source baseline.

## Changes

- Managed workspace Pi chats, independent saved HUD chats, and ordinary ASK/ACT agent runs receive a compact identity and on-demand reference pointers.
- The server supplies ordinary/HUD launch guidance even without global Pi package discovery. First Mate’s validated extension supplies its coordinator, worker, or advisor context and exact feature/assignment identities.
- `herdr-docs list`, `read TOPIC`, and `path TOPIC` work offline without configuration, credentials, network access, or a source checkout. Topics cover overview, control, First Mate, and API discovery.
- Guide bodies are not eagerly injected. Restricted question, naming, and response-brief profiles keep their existing boundaries. Guidance grants no new permission and never bypasses human stage checkpoints, successor acknowledgement, project trust, or typed control receipts.
- Missing guide resources do not advertise nonexistent paths. First Mate root assignments with an explicitly null parent remain supported.

## Installation and compatibility

Install this wheel in a new versioned Python 3.11+ environment following the [server update procedure](https://github.com/ronnie3786/herdr-companion/blob/companion-v0.33.0-beta.1/herdr_harness/README.md#update-the-server). Build provenance is recorded in `source-revision.txt`; verify the wheel against `SHA256SUMS`. Preserve private configuration, credentials, state, previous service definitions, and the prior runtime for rollback.

Update the matching installed CLIs—including the new `herdr-docs` entry—and replace only the matching Herdr package entry in Pi settings with this wheel’s bundled Pi package. Preserve unrelated packages and user trust settings. Do not interrupt active agents to switch a server or reload an extension.

New Pi sessions load the updated package. Existing idle sessions using global package discovery can use `/reload`. Sessions launched with an explicit old extension path need a safe exit/resume without that override. First Mate’s new dispatches use the updated extension; already-running turns retain their current runtime.

The Mac signed-feed update and companion deployment are independent. Existing clients remain compatible; this awareness change adds no API mutation or state migration and requires no iOS binary release. See [agent awareness](https://github.com/ronnie3786/herdr-companion/blob/companion-v0.33.0-beta.1/docs/agent-awareness.md) for exact coverage and limitations.

## Verification

From any directory, run `herdr-docs list`, `herdr-docs read overview`, and `herdr-docs read first-mate`. In a new HUD or workspace chat, ask what Herdr Companion can do and where its documentation is. In First Mate, ask how its workers and human checkpoints are managed. The agent should discover the relevant installed reference, not claim that every Mac UI control is available or that discovery grants authority.

# Herdr Companion server 0.59.0b1

The lead First Mate reaches the other machines of its companion's roster, so it
can live on the Mac you use without losing the features that run elsewhere.

- Adds `first-mate-lead-peers-v1`, advertised by `GET /api/v1` and
  `GET /api/v1/first-mate/capabilities`.
- A lead's peers are the other machines in the private configuration's
  `[machines]` roster whose API credential is configured on its host: the same
  machines `herdr-control --machine <id>` reaches. Credentials are resolved by
  the same code as the control CLI, and never logged or returned.
- `fm_fleet` adds `other_machines`: each peer's active features, or `offline`
  with when it last answered. The other lead tools take an optional `machine`.
  Peer calls run off the runtime loop with a 6-second timeout; a peer that does
  not answer counts as offline for 30 seconds, so one turn never waits on it
  twice.
- New `POST /api/v1/first-mate/lead/remote` runs one lead tool against this
  machine's features for a lead on another machine, authenticated with this
  companion's own API credential. The asking lead allows relays and new
  features only on the human's own turn; request IDs are namespaced by the
  asking machine, so a retried relay posts once. A relayed message's metadata
  and journal record `lead_machine`.
- The lead's summary adds `machine` (this companion's roster ID and name) and
  `peers` (`[{id, name, url}]`). A snapshot machine sent with a message may be
  marked `offline`.
- The shared credential resolution moves into `control_cli.machine_client`;
  `herdr-control` behaves as before.

## Install separately

This package also carries everything in companion 0.57.0b1 (First Mate reliability);
a host still on 0.56.0b1 gets both. Read those notes before upgrading one.

Use the server update procedure in `herdr_harness/README.md`. Build/install in a
new Python 3.11+ runtime, preserve private configuration, take a consistent state
backup, validate the package and configuration, then explicitly switch the
companion and matching CLI/Pi integration. The companion and its bundled First
Mate Pi extension must be upgraded together. There is no database change.

Upgrade each machine a lead reaches too: an older companion answers the remote
route with 404, and the lead reports that machine needs an update.

The signed Mac updater installs only the app. Publishing this package performs no
server cutover and no iOS installation.

## Verify

Confirm `first-mate-lead-peers-v1` in the authenticated capabilities, then
`GET /api/v1/first-mate/lead` after `POST` and check that `peers` lists the
machines you expect. Ask the lead "What needs me?" and expect other machines'
features. See docs/first-mate/lead.md.

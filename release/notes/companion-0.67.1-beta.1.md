# Companion 0.67.1b1

This companion release carries forward the compact, versioned First Mate chat
and Overview reads from 0.67, including cursor pagination and conditional
acknowledgements for unchanged views. It also carries forward the Pi connection
fix already deployed.

- First Mate's existing read APIs and native-client views remain available.
- Pi semantic connections now tolerate temporary backpressure during update
  bursts, while preserving event order and bounded recovery behavior.
- The companion validates newline-delimited Pi records independently when a
  socket read contains more than one record boundary.
- Existing Mac, iPhone, and web clients remain compatible because the semantic
  wire protocol stays at version 1.

No configuration migration is required. Install the companion server package
and the updated Pi package separately on each machine that owns Pi sessions.
Active sessions can finish with their already loaded extension; new sessions use
the updated package, and idle sessions can follow the
[Pi upgrade instructions](../../pi-semantic-bridge/README.md#upgrade-running-pi-sessions).
The Mac app updater does not install or restart companion server packages.

# Companion 0.66.0b1

First Mate Git resolves the feature's unique tracked checkout using local Git
repository and upstream evidence, collapses duplicate assignment directories,
and returns an explicit choice when the target is ambiguous. Existing assignment
URLs still resolve to their original checkout.

Live branch comparisons use the current target merge base. Historical workflow
commit inspection retains its captured baseline. Git viewing never fetches,
switches branches, or modifies a checkout.

Use Mac **0.71.0-beta.1** for the new default and grouped checkout menu. The API
fields are additive, and existing Mac, iOS, web, and Pi clients remain compatible.
No configuration or state migration is needed.

Install the wheel into a new versioned runtime, preserve the private configuration
and state, verify the installed package, then switch the companion service using
the [server update procedure](../../herdr_harness/README.md#update-the-server).
Keep the previous runtime and launcher for rollback. The signed Mac updater does
not install this server package.

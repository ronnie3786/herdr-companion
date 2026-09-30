# Companion 0.67.0b1

First Mate adds compact, versioned chat and independent Overview reads, cursor
pagination for conversation history, and conditional acknowledgements for unchanged
views. Mac **0.73.0-beta.1** uses the new reads when advertised. Existing snapshot,
board, document, session, mutation, web, iOS, and Pi contracts remain compatible.
Successful JSON GET responses can use negotiated gzip compression.

Read-only verification assessments use a bounded ten-second cache and per-feature
single-flight computation. Every reuse checks current evidence, selection, and Git
state. Dirty worktrees and unavailable identity probes are reassessed. Mutation and
gate decisions continue to calculate fresh evidence. Compact summaries retain the
gate set and tested revision proof required to display Verified.

No configuration or state migration is required. Install the exact wheel into a
new Python 3.11+ runtime, preserve private configuration and state, and run the
packaged-install checks before switching services. Keep the previous runtime and
launcher for rollback. Follow the [server update procedure](../../herdr_harness/README.md#update-the-server).
The signed Mac updater does not install this package. Server rollout is separate
from publishing the Mac app.

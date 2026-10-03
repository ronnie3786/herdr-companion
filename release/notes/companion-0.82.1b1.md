# Companion 0.82.1-beta.1

Main Chat now prepares skims when Pi saves the completed answer, even when no client has opened that chat. The reader reuses the cached skim. Reconnect checkpoints prepare the latest completed answer, while streaming, failed, cancelled, and tool-only replies remain ineligible.

This update also includes the landed First Mate fixes for preserving current user direction across stage checkpoints and retaining usage evidence in oversized transcript records.

Install this companion package separately on each server. The Mac updater does not install it. Existing compatible Mac and iOS clients continue to work; older companions retain on-demand Main Chat skimming. Preserve the private configuration and state, and wait for active companion-owned jobs to finish before restarting a busy server. Keep the previous runtime for rollback.

To verify: leave a Main Chat closed while a long reply finishes, allow the skim model to complete, then open the chat. Its skim should already be cached without another model run. Model failures still leave the full reply available.

# Companion 0.27.0b2

PR Review now resumes preparation interrupted by a backend restart and preserves
the originally selected skill runs. Refresh retries a failed initial preparation
through checkout, workspace creation, and skill launch.

Selected agent skills now use Pi by default and invoke its `/skill:<name>` command,
including runs queued by earlier versions. Provider and model choices come from
the host's existing Pi settings.

Repository preparation uses partial clones without a default-branch checkout and
a separate configurable timeout (15 minutes by default). Timed-out commands stop
their subprocess group. Errors identify the preparation stage without exposing
private command arguments or checkout paths.

This is a companion server update. Existing Mac clients with `pr-review-v1` remain
compatible and do not need an app update. After updating the review host, use
Refresh on a failed review, then check Agents for the original selected skills.
Keep the previous runtime and a consistent state backup for rollback.

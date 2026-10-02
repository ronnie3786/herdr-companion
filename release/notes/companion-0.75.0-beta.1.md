# Companion 0.75.0 beta 1

Adds configurable PR Review Agents, team selection, isolated reviewer runs, retained raw reports, and automatic consolidation tied to the selected reviewers and PR revision. Reviewer profiles and copied skill packages remain in the operator's private state. A generic Comprehensive reviewer is included; it uses the execution host's default Pi model.

Use Mac **0.88.0-beta.1** or later for the agent picker, reviewer cards, and profile editor. Older clients keep the legacy skill API. Existing review and agent-role records migrate additively.

Build and install this wheel in a new versioned Python 3.11+ runtime, update the matching installed CLIs and Pi package paths, preserve private configuration and state, and restart the affected companion services using the server update procedure in the README. Retain the previous runtime and service definitions for rollback. Mac updates do not install this package.

After updating, check `pr-review-agents-v1` in the authenticated PR Review capabilities and Agent Roles responses. In the Mac app, open **Settings → Agent Roles → PR Review Agents**, then select a reviewer when starting a PR review.

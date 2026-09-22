# Companion 0.31.0b1

First Mate supports private host defaults for coordinator, planning, and execution models and thinking levels. Delegation selects a planning or execution profile; configured role models take priority over legacy agent-supplied model overrides. Feature-specific coordinator settings continue to apply to the next conversation turn. New dispatches, retries, and handoff successors resolve the current policy.

Additive model-selection metadata distinguishes requested settings from values observed in Pi state and validated saved session records. Unknown actual settings remain unknown. Normal Pi tools, skills, extensions, project context, workflow authorization, session ownership, and handoff acknowledgement checks remain available and enforced.

## Installation and compatibility

Install the wheel into a new versioned Python 3.11+ environment following the [server update procedure](https://github.com/ronnie3786/herdr-companion/blob/companion-v0.31.0-beta.1/herdr_harness/README.md#update-the-server). Preserve private configuration, state, and the previous runtime. Retarget the matching installed CLIs and bundled Pi package, then restart the companion at an appropriate boundary.

Configure coordinator and role defaults using the private `first_mate` settings described in [runtime configuration](https://github.com/ronnie3786/herdr-companion/blob/companion-v0.31.0-beta.1/docs/first-mate/runtime.md). Use provider-qualified models available on that host. Running workers retain their current dispatch settings until completion or an acknowledged handoff; changing defaults does not rewrite an active session.

Mac 0.31.0-beta.1 displays model-selection details. Existing native clients remain compatible, and the wheel includes the matching browser interface. The Mac updater updates only the app. This release does not distribute an iOS binary.

After deployment, open First Mate model settings and inspect agent rows and saved session history. Verify the actual model and thinking level for a new dispatch and compare them with the requested role policy.

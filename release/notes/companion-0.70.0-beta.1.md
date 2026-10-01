# Companion 0.70.0 beta 1

This package supports the agent viewer in Herdr Companion 0.78.0 beta 1 and remains compatible with older native clients.

- Saved Pi session responses include tool-call identity, arguments, results, thinking text, stable message indices, and writer activity. Provider thinking signatures are excluded.
- First Mate cancels compaction only within validated managed sessions and no longer writes Pi's shared compaction setting.
- Research Scout adds an explicit specialist profile, an exact host model pin, and private instruction snapshots. Startup validates the observed model before the task begins.
- The primary assistant remains First Mate; feature coordinators are Second Mates (Feature leads).

Install the wheel in a new versioned runtime, back up private configuration and state, validate Fleet paths, and update the companion service, enabled background workers, CLI wrappers, and matching Pi package. Preserve the separate terminal service. Follow the server update procedure in herdr_harness/README.md.

Restore compaction.enabled in private Pi settings after upgrading if an earlier supervisor disabled it. Reload existing ordinary Pi sessions. Configure exact-model compaction thresholds and research_scout_model, optional research_scout_thinking, and research_scout_instructions_file privately. See docs/first-mate/roles-and-sessions.md. No provider credentials or company instructions are included in this package.

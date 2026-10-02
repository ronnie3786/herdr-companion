# PR Review Agents

- Configure reviewers in **Settings → Agent Roles → PR Review Agents**, with private prompts, copied skill packages, avatars, and teams. The bundled Comprehensive reviewer uses the execution computer's default Pi model.
- Start a PR review by choosing agents or a whole team. The Agents tab shows each reviewer, its raw report, and the consolidator. Add reviewers or rerun them to rebuild the consolidated report.
- Consolidated HTML reports link to the raw reports and identify incomplete coverage. Reports stay tied to their PR revision.
- PR Review uses the First Mate purple glass appearance.
- Viewed-file changes support undo (⌃Z) and redo (⌃⇧Z), with ordered saves and protection against replies from an earlier PR revision.

Install companion **0.76.0b1** or later with `pr-review-agents-v1` on each review host. The Mac updater installs only the Mac app. Older companions retain the legacy skill review flow.

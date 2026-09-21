# Companion 0.28.0b2

First Mate and its spawned agents use the normal Pi tool environment, including Bash, file tools, skills, project context, and configured extensions. This includes research and review assignments, nested agents, and internal advisors. The coordinator keeps short replies and delegates substantive work through instructions rather than a reduced tool profile. It can also use the feature's bounded document and session readers.

Inspection assignments preserve their shared checkout by instruction, while implementation assignments keep their isolated worktrees. Commands and tools use the assigned working directory, normal Pi configuration, and host permissions. Existing workflow authorization, handoff acknowledgement, assignment tracking, and authenticated API checks remain in place. Agent-spawning skills use tracked First Mate delegation so work stays visible beside the main conversation.

## Installation and compatibility

Install the wheel in a new versioned Python 3.11+ environment and follow the [server update procedure](https://github.com/ronnie3786/herdr-companion/blob/companion-v0.28.0-beta.2/herdr_harness/README.md#update-the-server). Preserve private configuration, state, and the previous runtime for rollback. Update the matching installed CLIs and Pi package entry, then restart the companion service.

The First Mate API remains compatible with existing Mac, iOS, and browser clients. Updating the Mac app alone does not enable this server change. Current saved conversations receive the new policy on their next dispatch; already running agents keep the tools they launched with until then.

Verify by asking for a brief CLI lookup and its output. Missing binaries, authentication, and ordinary host permissions must still be configured on the companion host.

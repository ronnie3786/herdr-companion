# Herdr Companion 0.28.0 Preview 3

First Mate uses the normal Pi tool environment with the matching Companion 0.28.0b2 server: Bash, file tools, skills, project context, and configured extensions. The coordinator and spawned agents no longer receive a reduced First Mate tool profile. Installed CLIs run in the assigned workspace with the host's configured PATH.

The main conversation keeps brief replies and delegates substantive work to tracked agents through instructions rather than missing tools. Inspection assignments still direct agents to preserve the shared checkout. Normal host permissions, Pi trust settings, workflow checkpoints, and human authorization remain in place.

This Mac preview retains styled Markdown and the **All Machines** feature list from Preview 2.

## Update and verification

Choose **Herdr Companion → Check for Updates…** to install this preview. Install the separately released [Companion 0.28.0b2](https://github.com/ronnie3786/herdr-companion/releases/tag/companion-v0.28.0-beta.2) on each host where you want the CLI changes. The Mac updater does not update the server.

The updated companion applies the normal tool environment on the next agent dispatch, including continued saved conversations. Agents already running keep their current tools until their next dispatch. Ask First Mate to run a short CLI version or documentation lookup and report its output.

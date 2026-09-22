# Herdr Companion 0.31.0 Preview 1

First Mate shows the model and thinking level Pi actually selected in agent rows and saved session history. Requested settings are labeled separately when execution has not yet been observed. Open the conversation's model settings to inspect the host's coordinator, planning, and execution defaults.

The companion can route planning and execution to separate configured models and thinking levels. New messages, retries, and handoff successors use the current policy while preserving saved conversations, normal Pi tools, and workflow authorization checks. Running dispatches keep their settings until they finish or complete a safe handoff.

## Compatibility and setup

Model routing and selection details require the separately installed companion 0.31.0b1 package. Existing clients and older servers remain compatible. Configure role defaults privately on each host; no provider or paid model is selected by the release itself. The Mac updater does not install or restart the server.

Use **Herdr Companion → Check for Updates…** to install this preview. In **First Mate → Agents**, inspect an agent and its saved sessions to verify the actual model and thinking level. Existing usage and cost breakdowns remain available.

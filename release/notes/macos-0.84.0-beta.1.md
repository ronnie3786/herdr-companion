# macOS 0.84.0-beta.1

## Agent Roles

Open **Settings → Agent Roles** to configure First Mate's built-in roles or add a
custom specialist. Edit the name, when-to-use guidance, optional system prompt,
and delegation setting. Custom roles use the existing model profiles.

The **Skills** tab reads configurable folders on this Mac, with searchable
alphabetical tiles, source filters, selection counts and token estimates. Choose
the execution computer, select skills, and save to copy those packages and their
supporting files there. **Update Copies** refreshes saved copies after local changes.

Unconfigured built-in roles retain automatic skill discovery. Configured roles
advertise only their selected skills, including an empty selection. New custom
roles start empty, and Recovery Advisor remains restricted. Existing conversations
and queued assignments keep their saved role and skill snapshots.

## Compatibility and installation

Agent Roles requires the separately installed **companion 0.74.0b1** package,
advertising `agent-roles-v1`, and its matching Pi extension. Pi must support the
strict skill controls verified with **0.87.1**. Older companions show an update
notice; other existing app features remain available. The Mac updater installs
only the app, not companion servers, Pi packages or iOS builds.

With preview updates enabled, choose **Settings → Updates → Check for Updates…**
and install **0.84.0-beta.1**, build **133**. Then open **Agent Roles**, choose a
computer, configure a role and save. Start a new assignment or conversation to
use the updated role. See [Agent Roles](https://github.com/ronnie3786/herdr-companion/blob/main/docs/agent-roles.md)
for folder access, copying limits and snapshot behavior.

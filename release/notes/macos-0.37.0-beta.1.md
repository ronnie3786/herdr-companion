# Agent Profiles

- Edit SOUL.md personality and USER.md preferences in Settings → Agent Profiles or Fleet → Agent Profiles.
- Keep Personal and Work separate. Explicitly share a profile from one configured owner, with optional machine-specific additions.
- Inspect the effective profile, applied revision and sync status. Assigned hosts retain their last accepted revision offline.
- Review agent-proposed changes before applying them; conflicts cannot silently overwrite newer edits. Restore earlier content as a new revision.
- Workspace chats, saved HUD conversations and First Mate receive execution-host preferences without changing project rules, permissions or human gates. Existing conversations and assignment retries keep their pinned snapshot; new conversations adopt accepted changes.

## Required components

Install companion **0.37.0b1**, including its `herdr-profiles` CLI and matching Pi package, on each participating agent host. This Mac update does not install the server. Older servers show an upgrade requirement in the profile editor; existing client APIs remain compatible.

New installations start with empty, unassigned Personal and Work profiles. Select the data machine and profile owner deliberately. Documents are private service data, not repository files, and should never contain credentials. See `docs/agent-profiles.md` for setup, sync, retention and adoption boundaries.

This preview uses Apple Development signing and is not notarized. Signed-feed and archive verification remain enabled.

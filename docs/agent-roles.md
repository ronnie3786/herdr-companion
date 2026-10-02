# Agent Roles

**Settings → Agent Roles** configures First Mate's roles on the selected execution
computer. The picker reads skill folders on the Mac running Herdr Companion.
Saving a role copies its selected skill packages to that execution computer over
the existing authenticated companion connection. It does not install a companion
update or run a skill.

## Configure a role

1. Select the computer that will execute the role.
2. Choose a built-in role, or use **New role** for a custom specialist.
3. In **Profile**, edit the name, when-to-use guidance, optional system prompt,
   and whether this role may delegate. Custom roles choose one of the existing
   model profiles; the execution computer's model and thinking pins still apply.
4. In **Skills**, connect local folders if macOS requests access. Herdr checks
   the current user's `~/.agents/skills`, `~/.codex/skills`, `~/.claude/skills`,
   `~/.config/dox-agent/skills`, `~/.pfw/skills`, and `~/.pi/agent/skills`.
   Missing optional locations are quiet. **Connect folders** suggests conventional
   locations when access is needed; **Add folders** accepts other project or shared
   locations. Access is saved as a read-only security-scoped bookmark on this Mac.
5. Configure the selection, search or filter by source, and toggle skill tiles.
   **Select shown** adds the filtered results. **Clear** removes the whole
   selection. **Copy from role** copies a saved selection on this execution host.
6. Save. A successful response confirms that the role and its copies are stored
   on the selected computer. **Update Copies** sends changed local skill files
   for an already-saved role without changing its profile.

Names and descriptions are editable private data. Built-in identities map to
existing runtime boundaries:

| Identity | Execution |
| --- | --- |
| `first_mate` | Lead First Mate across features |
| `second_mate` | One feature's coordinator |
| `worker` | Execution profile |
| `planner` | Planning profile |
| `architect` | Architect profile, including its existing required model pin |
| `research_scout` | Research Scout profile, including its required model pin and instructions |
| `recovery_advisor` | System-managed advisor with no skills |

Fresh built-in prompts are empty. An unconfigured built-in keeps Pi's existing
automatic skill discovery. After configuring a selection, only its checked skills
are advertised, including when the selection is empty. New custom roles start
with no skills. Recovery Advisor remains locked and cannot be edited or deleted.

## Copies and running work

Skill packages include `SKILL.md`, scripts, and references inside the package.
Executable script permissions are retained. Hidden files, common credential
files, and dependency/cache directories are excluded. A symlink to a whole skill
folder is supported; a package cannot copy files outside that resolved folder.
When a link points outside a granted folder, **Review folders** identifies its
real target and offers **Grant access**. Several links to the same target folder
produce one notice. All granted folders remain accessible together during both
discovery and copying. Automatic-discovery roles can browse readable skill tiles
before opting into a selection.

Copying is bounded to 1,000 files and 8 MiB per save, with 2 MiB per file. A failed
copy leaves the saved role unchanged and retains the editor draft.

Copies are private and versioned by content. Updating one role does not change a
different role's saved copy. Changes on the source Mac are adopted by saving or
updating copies again. Copies on other execution computers are independent.
Skill scripts that refer to absolute host paths or external tools may still need
those dependencies configured on the execution computer; Herdr does not rewrite
scripts or machine-specific paths.

A selected skill missing on the source Mac can retain its existing execution-host
copy. A selected skill missing from the execution host is excluded at launch;
Herdr never falls back to all skills. The editor identifies unavailable selections
so they can be refreshed or removed. Token estimates describe skill metadata in
the prompt, not the full skill body, and are approximate.

New assignments receive the role's saved prompt, delegation policy, and exact
skill paths. A conversation, assignment retry, or continuation keeps its pinned
snapshot. Start a new conversation or assignment to adopt changes. Deleting a
custom role prevents new delegation to it and preserves already-queued work.

Second Mate receives the available roles and their when-to-use guidance. Its
existing `fm_delegate` tool accepts an optional `agent_role_id`. IDs select roles;
display names and freeform assignment labels do not. The role selects an existing
model profile and cannot bypass specialist model requirements, workflow stages,
workspace boundaries, or human checkpoints. Disabling delegation removes the
dispatch tools and also rejects dispatches on the server.

The allowlist controls Pi's skill discovery and prompt catalog. It is not a
filesystem sandbox. Existing repository instructions, tools, extensions, trust,
and authentication rules still apply.

## Compatibility and storage

Requires a companion advertising `agent-roles-v1`, the matching First Mate Pi
extension, and Pi supporting `--no-skills`, repeatable `--skill`, and mutable
`before_agent_start.systemPromptOptions.skills` (verified with Pi 0.87.1).
The Mac app displays an update notice for an older companion. Older apps and the
web and iOS clients continue using the existing First Mate API unchanged.

Role settings live in the companion's private state directory in
`agent-roles.sqlite3`. Copied packages are under `agent-role-skills/`; pinned
execution snapshots are in First Mate's existing private runtime directory.
Agent Roles is separate from Agent Profiles. Profile preferences continue to be
appended alongside role instructions and do not grant new authority.

The authenticated `GET /api/v1/agent-roles` returns the roles, global revision,
and execution-host catalog. Its additive `missingRoleSkills` mapping identifies
missing copied skill IDs by role, including when another role's current copy is
still available. Native clients use this for execution-copy warnings, independently
of local folder-access notices. Host discovery warnings do not populate the local
picker. Older companions remain supported through their available-package catalog.
`POST` saves or deletes a role using
`expectedRevision`; a stale edit gets HTTP 409 instead of overwriting another
client's changes. Optional `skillBundles` contain only selected packages, with
relative file paths and base64 contents. Role contents and packages require full
authentication and are unavailable to scoped agent credentials.

For operator-managed host catalogs, `[first_mate.skill_sources]` in private TOML
maps source labels to directories. Machine overrides use the existing configuration
rules. The native picker uses its local folders; it does not silently display a
remote machine's discovered skills.

The Mac app ships through its signed release feed. Companion server packages and
Pi extensions are updated separately. Creating or saving a role never deploys
these components.

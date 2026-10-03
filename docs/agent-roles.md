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
   Search is fuzzy: letters typed in order match across words (`swui` finds
   `swiftui-pro`), small typos still match, and every word must match a skill's
   name or description. Results are ranked with name matches first; clearing the
   search returns to the alphabetical sections. **Select shown** adds the filtered results. **Clear** removes the whole
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

## Share roles with teammates

On a companion advertising `agent-roles-share-v1`, the **Share** menu in
**Settings → Agent Roles** exports roles to a file and imports a file someone
shared with you. Roles always move between files and the computer shown in
**Runs on**.

**Export Roles…** lists the roles on that computer. First Mate roles come first;
PR review agents are grouped by team, and a team's checkbox selects its members.
Custom roles, PR review agents, and built-in roles you changed are included.
Built-in roles still at their defaults are listed as **Default** and are never
written to the file. Recovery Advisor is never shared. Each role carries its
name, guidance, prompts, delegation setting, model profile, avatar, team name,
and the exact skill copies it runs on that computer, including scripts. A skill
without a stored copy, such as one found in a host skill folder, is shared by
name only. Agent Profiles, machine names, revisions, and file paths are not
included. Export stops if a prompt or skill file contains a private key and names
where it is. The file is plain JSON named `herdr-roles-<date>.json`, so it can be
read before it is shared.

**Import Roles…** checks the file, then shows a plan for the computer in **Runs
on** before anything changes:

- **New** roles are selected. Roles whose skills aren't all available start
  unselected and say which skills they would leave out.
- A role with an ID the computer already has, including a built-in role, shows
  **Replaces your …** with the fields that would change. It starts unselected
  unless it replaces a built-in that was never changed. Import never changes an
  existing role you didn't select.
- Roles that already match are summarized in one line.
- PR review agents join a team with the same name, ignoring case, or create it.
- Each skill shows whether its copy is new, already on the computer, kept
  separate, already available by name, or not available. Skill files and
  `SKILL.md` can be read before importing.

Skills are matched by their files, not by name. A shared copy identical to one
the computer already has is reused. If the computer already uses that skill ID
for different files, the shared copy is saved under its own ID and the existing
copy and the roles using it are untouched. Imported copies appear on the Skills
tab as **Saved copies on <computer>**; they can be removed but not refreshed from
your Mac. Saving or updating a role later from a Mac that has a skill at the
same location replaces that role's copy with the Mac's, as it does today.

Importing applies every selected role in one change. If the roles or skills on
that computer change while the plan is open, Herdr shows the updated plan
instead of importing something you didn't review. Running and queued work keeps
its pinned snapshot. Imported prompts and skills run with your permissions on
that computer, so review them as you would code from a teammate.

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

For sharing, `GET /api/v1/agent-roles/export?preview=1` lists exportable roles
and their stored skill sizes. `GET /api/v1/agent-roles/export?roleIds=…` returns
`{document, summary, warnings}`, where `document` is the file:
`{format: "herdr-agent-roles", version: 1, exportedAt, roles, skills}`. Roles use
the role fields above plus `skillContent` (skill ID → content hash); skills use
the `skillBundles` shape plus `contentHash`, or only `{id, name, description,
source}` for a name-only reference. Readers reject other formats and newer
versions and ignore unknown fields with a warning; new optional fields do not
change the version. `POST /api/v1/agent-roles/import` with `dryRun: true`
returns the plan and a `planDigest`; the commit repeats the digest with
`expectedRevision`, `roleIds`, and `replaceRoleIds` for every selected role
that replaces an existing one. The Mac also sends `localSkills`, the content
hash of its own copy of each skill in the file, on both requests. A shared copy
that differs from the Mac's own copy, or from a copy already on the computer,
is stored under a derived ID; without `localSkills`, Mac catalog skills are kept
separate unless the computer already has identical files. A stale revision returns 409
`agent_role_conflict`, and a changed plan returns 409 `import_plan_changed`.
Dry runs and imports that change nothing do not bump the revision or publish
`agent_roles.changed`. Files are limited to 128 roles, 1,000 skill files, 8 MiB
of skill files, and 2 MiB per file.

For operator-managed host catalogs, `[first_mate.skill_sources]` in private TOML
maps source labels to directories. Machine overrides use the existing configuration
rules. The native picker uses its local folders; it does not silently display a
remote machine's discovered skills.

The Mac app ships through its signed release feed. Companion server packages and
Pi extensions are updated separately. Creating or saving a role never deploys
these components.

## PR Review Agents

On a companion advertising `pr-review-agents-v1`, Settings shows a separate,
collapsed **PR Review Agents** section. Each saved reviewer has a name, avatar,
optional team, review prompt, and the same explicit skill selection and package
copying controls as other Agent Roles. Only **Comprehensive** is bundled. Private
specialists and teams belong in the companion's role store.

The review prompt is a multi-line editor, so Return starts a new line.

**Team** is a drop-down of the teams saved on the selected computer. **New Team…**
saves a team and puts the agent on it; **Edit Teams…** renames or deletes teams.
On a companion advertising `pr-review-teams-v1`, each team has a stable ID and
agents store that ID (`teamId`), so a rename keeps every member and two teams never
merge by name. Team names are unique, ignoring case. Deleting a team leaves its
agents without a team; existing reviews keep their reports. The first read on an
upgraded companion turns team names saved by earlier versions into teams with
stable IDs. Older Mac clients still send a team name; the companion matches it to
a saved team or creates one. Against an older companion, the drop-down offers the
team names agents already use and **New Team…** stores the name when the agent is
saved; renaming and deleting teams need the companion update.

A blank review prompt remains blank in storage and uses the faded adversarial
review example at launch, with the actual PR URL inserted. Review agents use the
execution computer's global Pi default model, without First Mate routing or
delegation settings. Their purpose is `pr_review`; First Mate's worker catalog
excludes them. Older roles decode as `worker` and remain compatible with earlier
clients. New profiles cannot be saved to a companion missing the capability.

Select these agents when starting a review or adding another pass from its Agents
tab. Runs retain the role and selected package versions captured at queue time.
See [PR Review](pr-review.md) for automatic consolidation, history, and incomplete
coverage behavior.

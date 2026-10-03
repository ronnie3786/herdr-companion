# Agent Roles sharing — follow-ups (findings layer, 2026-10-03)

Branch `feature/agent-roles-share-20261002`. This is a dated layer of review findings, not a strict spec.

## Shipped on the branch

- Companion: `agent-roles-share-v1`. Export preview and document
  (`GET /api/v1/agent-roles/export`), and a planned, atomic import (`POST /api/v1/agent-roles/import`).
  Covered by `tests/test_agent_roles_share*.py`.
- Mac: Share menu, Export and Import sheets, and the Saved copies card. Covered by the
  `AgentRolesShare*` and `AgentRoleSkillContentHash` suites.
- Fixed from adversarial review:
  - Server: every server finding.
  - Mac F1: a local skill this Mac can't read now claims its ID with a hash that never matches.
  - Mac F2: Share waits while the skill catalog refreshes.

## Open Mac findings (not started)

1. **Cancel a dry run when the import sheet closes (F3).**
   - Store the import task and a re-plan task. Add `startImport(url:)` and `cancelImport()`, called from the sheet's `onDismiss`.
   - Never cancel the commit.
   - Don't cancel inside `closeImport()`: both `openImport` paths call it first.
2. **Rows with empty or duplicate IDs (F4, F8, F13).**
   - Require unique, non-empty IDs only among selectable (create/update) rows.
   - Give the role `ForEach`s in `AgentRolesImportSheet` positional identity.
   - Add a test with two ID-less invalid rows plus one valid role.
3. **A commit that fails without a reply (F5).**
   - For transport errors, 5xx and decoding failures, say "The import wasn't confirmed. Reload Agent Roles to see what changed."
   - Re-plan, keeping the user's choices.
   - Mark the store for reload with `markNeedsReload()`, honored by `loadIfNeeded`. Hold the reload until the sheet closes, so the generation doesn't change under an open sheet.
4. **Partial `SKILL.md` previews (F9).** Decode `skillTextTruncated`.
   - When it's set, or when SKILL.md's size is larger than the preview, show "Showing the first 64 KB of N KB."
   - When the preview is empty but SKILL.md has bytes, show "SKILL.md is too large to preview (N KB)."
5. **Hidden formatting characters (F10).**
   - Decode `hiddenText` and warn on that skill row.
   - Make bidi controls (U+202A–U+202E, U+2066–U+2069) and tag characters (U+E0000–U+E007F) visible as `\u{XXXX}` in the SKILL.md and prompt previews.
6. **Wording for kept-separate and available skills (F11).** Decode `separateReason` (`computer`, `mac`, `file`).
   - Word each reason separately. With no reason, use neutral wording.
   - For `.available`, say "<machine> already has this skill and uses its copy as is."
7. **Export confirmation hidden by unsaved edits (F12).** Add a `store.exportMessage` that `adopt()` and saving don't clear, and show it whether or not the editor has unsaved edits.
8. **Missing tests (F14–F17).**
   - Closing the sheet, or a connection change, during a dry run, including the dry run that follows a 409.
   - `{}` versus omitted `localSkills`.
   - Header strictness: a boolean `version` and empty `roles`.
   - Commit confirmation: a stale overview, and a dry-run reply returned for a commit.
   - Closing the export mid-request, and a failed file write.

## Later (v2 candidates from the design critique)

- Copy roles straight to another machine.
- Add an imported role as a copy instead of replacing.
- Undo an import.
- A `herdr-roles` CLI.
- Write imported skills into the user's local skill folders.
- A custom `.herdrroles` type with double-click import.

# Herdr Companion 0.101.0-beta.1

## Share Agent Roles with teammates

- **Settings → Agent Roles → Share** exports your First Mate roles and PR review
  agents, with the skills they use, to a JSON file, and imports a file a
  teammate shared. PR review agents are grouped by team; a team's checkbox picks
  its members. Built-in roles at their defaults and Agent Profiles aren't shared.
- Import shows a plan first: new roles are selected, roles that would replace
  yours show what changes and stay unselected, and each skill says whether it's
  new, already on the computer, kept separate, or unavailable. Prompts, skill
  files and `SKILL.md` can be read before importing.
- Imported skill copies show on the Skills tab as **Saved copies on
  <computer>** instead of a missing-skill warning.
- Requires the matching companion server package (`agent-roles-share-v1`),
  installed separately. With an older companion, Share explains that the
  companion needs an update.

## PR Review Agents: teams, prompts and skill search

- In **Settings → Agent Roles → PR Review Agents**, **Team** is now a drop-down
  of saved teams. **New Team…** creates one and **Edit Teams…** renames or
  deletes them. Agents follow a team's ID, so renaming a team keeps its members,
  and starting a review groups agents by team ID instead of by name.
- The review prompt is a multi-line editor: Return starts a new line.
- Skill search stays responsive with hundreds of skills. It is fuzzy and ranked:
  letters typed in order match across words, small typos still match, and name
  matches come before description matches.
- Saved teams need the matching companion server package (`pr-review-teams-v1`),
  installed separately. With an older companion, the drop-down lists team names
  already in use and **New Team…** still works; renaming and deleting teams wait
  for the companion update.

Sharing and saved teams need companion 0.83.0-beta.1, installed separately on each
host. The Mac update installs the app only. It does not restart companion servers
or interrupt their running tasks. Use **Herdr Companion → Check for Updates…** to
install the signed preview.

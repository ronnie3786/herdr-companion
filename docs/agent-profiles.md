# Agent profiles: SOUL.md and USER.md

Agent Profiles add optional personality and user preferences to Companion's
existing app awareness. Open **Settings → Agent Profiles**, or **Fleet → Agent
Profiles**. Select the **data machine** where the agent runs, not the computer
showing the conversation.

- **SOUL.md**: tone, personality, and collaboration preferences.
- **USER.md**: relevant user preferences and context. Never add credentials.
- **Machine additions**: small local additions without copying a shared profile.
- Existing repository **AGENTS.md**, system safety, project trust, current user
  requests, ASK/no-tool limits and First Mate role/human gates remain authoritative.

The companion service stores private, revisioned Markdown content. The names
SOUL.md and USER.md describe the documents, not files to commit to a repository.
The app edits them through the authenticated API; normal project files are never
rewritten. Initial Personal and Work profiles are empty and unassigned. No profile
is inferred from a computer's display name or automatically shared with peers.

## Share only the profile you choose

For example, own Personal on a home computer and Work on an always-on development
computer. Assign the work laptop to the development computer's Work profile. Edits
at that owner apply to both assigned machines without copying Personal there.
There is no global inherited USER.md in this release; shared named profiles plus
machine additions keep the privacy boundary explicit.

The assigned host fetches only the selected profile's current revision from its
explicitly configured owner, using that owner's private API credential. It never
imports the owner's other profiles or revision history. The owner must appear in
the host's private roster, with its own credential. Cross-machine transport uses
the existing HTTPS/no-redirect fleet client. A failed initial assignment leaves
previous settings unchanged.

The server refreshes remote bindings every 60 seconds, independently of the app.
**Sync now** refreshes explicitly. Offline hosts keep their last accepted copy;
sync status and last successful sync are visible. Lower owner revisions or changed
contents at the same revision are rejected, not silently installed. A restored
profile becomes a new, higher revision. Owner migration is an explicit new
assignment, not an automatic election or multi-master merge.

## Editing, conflicts, and proposals

Edits use the revision that was read. A conflict preserves the editor's draft;
reload and reconcile deliberately. Restoring history creates a new revision rather
than deleting later changes. The last 100 revisions are available per profile.
The bounded proposal inbox retains pending proposals and recent decisions.

Agents can read their profile and propose changes with `herdr-profiles`:

```sh
herdr-profiles effective
herdr-profiles --machine desktop list
herdr-profiles --machine desktop get PROFILE_UUID
herdr-profiles --machine desktop propose PROFILE_UUID \
  --expected-revision 3 --soul-file /private/path/SOUL.md \
  --user-file /private/path/USER.md --reason 'Requested preference' \
  --request-id NEW_STABLE_UUID
```

Choose the **profile owner**, not a cache host, for a proposal. Proposing does not
change effective instructions. Review the diff in Settings/Fleet and approve or
reject it. A proposal based on an older revision cannot overwrite a newer edit.
ASK runs, First Mate coordinators/advisors and read-only workers cannot submit
through this CLI; they can present suggested wording without mutating state.
An isolated First Mate worker may propose an explicitly authorized preference
change, still requiring review and preserving its assignment scope. These policy checks
are not an OS sandbox: ordinary agents with filesystem/shell access retain their
existing permissions and must preserve the user's scope.

Every API mutation includes a stable request UUID. After an uncertain response,
retry only the exact same payload and ID. A reused ID with changed contents is a
conflict. Receipts and document changes commit atomically. The agent-facing CLI
has no approve, direct-update, assignment, or sync mutation command.

## When sessions adopt changes

- Workspace Pi conversations resolve and persist their effective snapshot before
  the first agent turn. It survives resume/reload and compaction.
- Saved HUD chats and ordinary headless runs receive a server-persisted snapshot;
  continuations keep the same snapshot.
- First Mate jobs snapshot at dispatch creation. Coordinator conversations and
  retries of an assignment retain their original snapshot. New independent
  assignments resolve the current host profile.
- Restricted contextual questions, PR-review questions, smart renames and response
  briefs do not receive profiles.

A profile edit does not silently rewrite an active conversation or assignment.
Start a **new conversation/assignment** to adopt it. Pi package upgrades require
new sessions or the documented idle `/reload` boundary; sessions launched with an
explicit stale extension path must safely exit/resume without that old override.
Unrelated standalone Pi sessions are not opted in merely because the package is
installed. A transient unavailable backend does not pin fabricated preferences.

Profiles are sent to the selected model as conversation context and retained in
private session records. They are not a password vault. Server-launched prompt
contents use owner-private files, not command-line arguments. Old snapshots can
remain in retained conversations after a profile is edited.

## Compatibility and operations

Requires matching companion server, Mac app, CLI and Pi package with
`agent-profiles-v1`. Older clients continue using existing APIs; an older server
shows an upgrade requirement in the editor rather than a mutation fallback. The
browser and iOS clients are not profile editors in this release, but agent runs
viewed there receive the same execution-host profile. Mac updates do not install
the server package.

Storage is `agent-profiles.sqlite3` under the configured `HERDR_STATE_DIR`, with
owner-only permissions. Include it in consistent SQLite backups. Keep the prior
runtime for rollback; no existing notes, conversations or First Mate state is
migrated by this feature. Disabling a binding stops it being used in new sessions
without deleting profiles or history. Keep private configuration and documents
out of public source, release notes and screenshots.

## Verification

Focused checks: `python -m unittest tests.test_agent_profiles`, profile snapshot
cases in `tests.test_agent_runs` and `tests.test_first_mate_runtime`, and
`node --test pi-semantic-bridge/test/agent-profiles.test.mjs`. Native tests cover
the editor's request/state handling. The release gate remains exact-source Verify,
privacy scanning, signed artifact preparation and installed-wheel verification.

Manual smoke: edit a synthetic profile, assign it locally, start a new pane and
HUD chat, and confirm their reported preferences. Assign a second host to the
first profile, edit at the owner, Sync now, and inspect the applied revision. Make
a concurrent edit and verify the old draft cannot overwrite it. Submit a proposal,
inspect its diff, approve it, and restore an earlier revision. Check that existing
conversations stay pinned and restricted helpers retain their original scope.

# First Mate projects

A project gives a reusable name to one folder on one configured companion
machine. Each new First Mate session has its own conversation and starting
prompt. The project is saved on the companion that owns the folder, alongside
First Mate state in the private `first-mate.sqlite3` database.

## Use projects on Mac

1. Open **First Mate → Projects** and choose **New project**.
2. Name the project and choose a machine from the configured companion
   connections. Choose **Browse…** to explore folders on that machine, or enter
   its folder path. The browser starts at the companion account's home folder
   when no path is supplied. It supports parent/home navigation, typed paths,
   hidden folders, and loading more entries.
3. Save the project. It is now available in **+ New session → Use a project**.
4. Choose the project, write the starting prompt, and choose **Start session**.
   The prompt becomes the first human message to the session coordinator, using
   that project's folder. For example, ask it to investigate a ticket before
   making changes. Saving a project alone does not start an agent.

Use **Manual setup** in New session to choose the machine, session title, and
absolute folder path directly. This keeps the existing manual creation route.
A project can also be created from the project picker without discarding the
starting prompt.

Edit a project from Projects to rename it or change its folder for future
sessions. Its machine stays fixed; create another project to work on another
machine. **Archive project** removes it from new-session choices without stopping
or modifying existing sessions. Enable **Show archived**, open the project, and
choose **Restore project** to use it again.

The Mac combines project lists from its configured companions and shows each
project's owner. Names and display order do not determine identity. Previously
loaded projects can remain visible during a connection failure, but managing a
project or starting work requires its owning companion to be available. Drafts
remain in the current form after request failures. They are not a cross-device
or restart-persistent draft service.

## Companion and client compatibility

The project UI requires the Mac app implementation and companions advertising
`first-mate-projects-v1`. Browsing folders additionally requires
`directory-browser-v1`. Both appear in the general API description and the
First Mate capabilities response. A companion without project support keeps
the manual setup route; old Mac, iOS, web, and Pi callers can continue using the
existing `cwd` feature-creation request. This change does not add a project
management UI to every client.

The signed Mac updater installs the Mac app only. Install the matching companion
package separately on each machine where projects or folder browsing are
needed, following the [companion installation instructions](../../herdr_harness/README.md).
No release version or live deployment is implied by this document.

## Authentication and filesystem access

The app sends requests to the selected machine's existing companion HTTP(S)
connection. Tailscale can provide private connectivity; browsing does not invoke
SSH, scan the tailnet, or mount another machine's disk on the Mac. It enumerates
the owning companion's local filesystem under that companion process account.

Project APIs, directory browsing, and project-based feature creation require the
main companion bearer token. Retired board credentials cannot use them.
If no main token is configured, these APIs fail closed with `api_token_required`
(503). Existing unauthenticated loopback development behavior for manual feature
creation is unchanged.

The folder browser returns immediate directory names and paths, never file
contents or recursive results. Hidden folders require an explicit toggle.
Accessible folders outside the home directory are allowed in this version;
there is no configured browse-root sandbox. Paths and `~` are resolved on the
companion, including symbolic links. A link entry discloses its resolved target,
and navigation returns the canonical path. Broken or disappearing entries are
omitted. POSIX names that cannot be represented as valid Unicode are omitted.

Saving or starting from a project checks that the canonical path is a directory
and that the companion can read and traverse it. macOS protected-folder access
belongs to the running companion process; an SSH shell's access does not grant
that process access. Resolve OS permissions on the owning machine if necessary.
If a saved canonical path is replaced by a link to another location, starting
fails with `project_directory_changed`; edit the project to select its intended
folder again.

## API

All paths below are relative to the owning companion's origin. Project mutation
requests require all listed fields and reject extra fields. `request_id` is a
nonempty string of at most 200 characters, generated once for a logical request
and reused when retrying that same request.

| Method and route | Request | Response |
| --- | --- | --- |
| `GET /api/v1/first-mate/projects` | Optional `scope=active`, `archived`, or `all`; default `active` | `{ok, server_id, projects}` |
| `POST /api/v1/first-mate/projects` | `{name, cwd, request_id}` | `{ok, project}`, status 201 |
| `PATCH /api/v1/first-mate/projects/{id}` | `{name, cwd, expected_revision, request_id}` | `{ok, project}` |
| `POST /api/v1/first-mate/projects/{id}/archive` | `{archived, expected_revision, request_id}`; `archived` is a boolean | `{ok, project}` |
| `GET /api/v1/directories` | Optional `path`, `show_hidden`, and `cursor` | Directory page described below |

A project contains `id`, `name`, `cwd`, `revision`, `created_at`, `updated_at`,
and nullable `archived_at`. The API accepts a single-line Unicode project name
of at most 160 characters and saves it trimmed. Paths are limited to 4096
characters and stored canonically. Revision starts at 1. Updates require the
current revision; stale changes return `stale_project_revision` (409). Archived
projects must be restored before editing. Restoring a project does not require
its folder to exist at that moment, but starting a session does.

`server_id` is the owning companion's persistent server identity, also available
in `GET /api/v1/first-mate/capabilities`. It is distinct from a Mac's saved
connection ID and a private configuration roster ID. A project identity must be
paired with its owner; matching names or folder paths across machines is not
identity matching.

To start from a project, send the existing feature route a project selection
instead of `cwd`:

```json
{
  "title": "Investigate garden scheduling",
  "goal": "Start with SYNTH-31. Investigate the current behavior and propose a plan.",
  "project_id": "fmp_synthetic_example",
  "expected_project_revision": 1,
  "request_id": "synthetic-start-01"
}
```

`POST /api/v1/first-mate/features` returns `{ok, feature}` with status 201.
`work_item_id` remains optional. Supplying both `cwd` and `project_id` is invalid.
The feature adds nullable `project_id`, `project_name`, and `project_revision`;
its existing `cwd` is the selected project's folder snapshot. Manual and legacy
features have null project fields. Existing feature title/goal limits remain
300 and 200,000 characters respectively. The goal's text is retained verbatim.

## Directory pagination and errors

A directory response has this shape:

```json
{
  "ok": true,
  "path": "/srv/projects",
  "parent_path": "/srv",
  "home_path": "/home/example",
  "entries": [
    {
      "name": "garden",
      "path": "/srv/projects/garden",
      "resolved_path": "/srv/projects/garden",
      "is_symlink": false,
      "can_open": true
    }
  ],
  "next_cursor": null
}
```

`parent_path` is null at the filesystem root. Pages contain at most 100 sorted
directory entries. Pass `next_cursor` unchanged with the same path and hidden
filter for the next page; null means the last page. Cursors bind to the canonical
directory, metadata, visible entries and resolved targets. A changed directory
or link target can invalidate a cursor. Reload from the first page after a stale
result.

Each request scans at most 20,000 immediate children and uses a three-second
cooperative scan budget. These limits include children hidden from display and
do not cancel an OS filesystem call that is already blocked. Oversized folders
return an error asking for a more specific typed path; the browser never silently
claims that a truncated scan is complete.

| Code | HTTP status | Meaning |
| --- | --- | --- |
| `directory_invalid` | 400 | Invalid path, non-folder, invalid Unicode, or unresolvable link loop |
| `directory_cursor_invalid` | 400 | Malformed pagination cursor |
| `directory_denied` | 403 | The companion cannot read or traverse the folder |
| `directory_missing` | 404 | The folder is no longer available |
| `directory_stale` | 409 | Directory contents or pagination scope changed; reload |
| `directory_too_large` | 422 | Scan limit reached; enter a narrower path |
| `directory_unavailable` | 503 | Another filesystem error; retry |
| `stale_project_revision` | 409 | The saved project changed; reload its details |
| `project_archived` | 409 | Restore the project or choose another project |
| `project_directory_changed` | 409 | The saved canonical path now resolves elsewhere |
| `idempotency_conflict` | 409 | A request ID was reused with different content |
| `server_identity_unavailable` | 503 | The project list cannot establish its persistent owner |

## Persistence, retry behavior, and verification

Schema migration 19 creates `fm_projects` and adds nullable project snapshot
columns to existing features. Existing sessions are retained and are not
automatically converted into projects. Renaming, retargeting, or archiving a
project never rewrites existing session folders or stops running work.

Project mutations use stored request receipts. Project-based feature creation
checks the original request receipt before consulting the current project or
filesystem. Retrying an accepted creation after the project was renamed,
archived, or its folder removed returns the same feature. Feature creation,
the exact initial human message, and the receipt commit in one transaction.
There is no second prompt-send call. A changed payload with the same request ID
is rejected instead of creating another session.

Focused verification uses synthetic temporary state and loopback servers:

```sh
.venv/bin/python -m unittest tests.test_first_mate_projects tests.test_directory_browser tests.test_first_mate_project_http
```

These cover migration, canonical paths, symlinks, access errors, bounded paging,
stale cursors, authentication, revision conflicts, rollback, and concurrent
idempotent retries. The Mac tests additionally exercise host selection, stale
responses, preserved drafts, and folder-browser state. Run the repository checks
in the [README](../../README.md#repository-checks) before delivery.

Run the focused native coverage from the repository root:

```sh
xcodebuild -project herdr-harness-mac/herdr-harness-mac.xcodeproj \
  -scheme herdr-harness-mac -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:herdr-harness-macTests/FirstMateProjectTests \
  -only-testing:herdr-harness-macTests/FirstMateProjectHTTPTests \
  -only-testing:herdr-harness-macTests/FirstMateProjectStateTests \
  -only-testing:herdr-harness-macTests/FirstMateProjectIntegrationTests \
  -only-testing:herdr-harness-macTests/FirstMateFolderBrowserTests \
  -only-testing:herdr-harness-macTests/FirstMateProjectsRenderTests test
```

The render suites exercise synthetic project creation, manual setup, archived
conflicts, large text, and the production navigation shell. They write PNGs to
the existing `HerdrRenderHarness` output directory. Launch a locally built Mac
app with `-HerdrDemoMode -HerdrFirstMateDemo` to explore the same flow without
connecting to a companion or starting real work.

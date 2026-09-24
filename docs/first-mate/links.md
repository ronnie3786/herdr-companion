# First Mate saved links

First Mate keeps the pull request you are working on, and other private links,
attached to the feature they belong to. A saved link survives reconnects,
session handoffs, app relaunches, and companion restarts, and it never changes
workflow status, revision, authorization, or queued model work.

Saving a link is not authorization to create a pull request, open a share, or
advance a workflow stage.

## Prominent pull request access on Mac

- **Overview** leads with a **Pull requests** section above the ordinary
  overview content. Every visible pull request is listed individually with its
  title, host, full destination, provenance, and **Open** and **Copy** actions;
  **Manage links** opens the **Documents** inspector directly on the **Links**
  collection.
- **Documents** repeats the same prominent section at the top, above a
  **Documents / Links** segmented control. The existing Documents sub-tab is
  unchanged: it still lists feature evidence with its producing agent and visit.
- The **Links** sub-tab lists pull requests first, then other links separately.
  Each row shows the exact saved destination and host (including a custom port),
  provenance when the link was detected or saved by an agent, and explicit
  **Open**, **Copy**, and **Hide** actions. **Show hidden** reveals hidden links
  with a **Restore** action.
- Ordering is deterministic (creation time, then link ID). No link is promoted
  to a primary PR from a title, branch name, repository label, or mention order.
- **Open** validates the stored URL and asks the system to open it only after
  the click. **Copy** writes the exact saved URL. Neither action guesses a
  repository or substitutes a feature or session URL.

The feature's saved links are private presentation records. The Mac app never
prefetches, previews, or automatically opens a destination, and it does not
publish links anywhere.

## Saving links

Users can add a link from **Documents → Links** with:

- an absolute `http` or `https` URL,
- an optional title, and
- an optional classification: **Automatic**, **Pull request**, or **Link**.

**Automatic** lets the companion classify an exact `github.com` pull request
URL; owner and repository casing folds so casing variants deduplicate into one
record without rewriting general URL paths. The explicit **Pull request**
classification covers enterprise GitHub and other HTTP(S) hosts without
trusting host-name resemblance. Invalid URLs (relative addresses, non-HTTP(S)
schemes, embedded credentials, control characters, malformed hosts or ports, or
values over 4,096 characters) are rejected when saving and again before opening
or copying. Bracketed IPv6 literals are valid destinations too, including a
custom port, path, query, and fragment; the brackets are preserved when the host
is displayed and Open and Copy still use the exact saved URL.

The same explicit save is available through the authenticated API, the
`herdr-first-mate add-link` CLI, and the scoped `fm_save_link` Pi tool for
coordinators and workers. Managed agents cannot supply provenance; the
companion derives it from validated feature-owned evidence. A repeated save is
quiet: the first record keeps its kind, provenance, and hidden state, and an
explicit user title replaces a derived or agent title.

## Automatic pull request discovery

When the companion advertises `first-mate-links-v1`, its runtime scans only
validated feature-owned evidence: current and retained managed sessions,
finalized dispatch jobs, accepted assignment outcomes, completed visit
summaries, and their documents. Exact
`github.com/<owner>/<repo>/pull/<number>` URLs are retained only when they match
the feature context. An explicit PR URL in the feature request is authoritative;
a bare PR number also requires a matching local Git remote. Otherwise the PR
must belong to that repository and match the feature ticket in structured PR
metadata (title or branch), or an unambiguous delivery statement in saved
evidence. A named target takes precedence over looser ticket matches.

A ticket mentioned elsewhere in a search result or PR body does not associate
the PR with this feature. Ordinary tool-output prose and background references
are ignored. When context is insufficient, use an explicit save. Draft and
ready-for-review references to the same qualifying PR deduplicate into one record. `/files` subpaths, query strings, and fragments canonicalize to the
pull request root.

Discovery boundaries:

- Only PR URLs are discovered automatically. General links are saved explicitly
  so ordinary documentation or tool-output URLs do not become bookmarks.
- Only validated feature-owned sources are read. Unrelated session files,
  arbitrary Pi history, and thinking blocks are never scanned.
- The scan is incremental with private cursors and is bounded per pass:
  lightweight paged inventory, record-unit session reads that leave a partial
  final line for its next append and skip an over-long line in bounded steps,
  and chunked outcome, visit, and document slices with an overlap tail.
- Text is treated as data. The companion never calls GitHub, `gh`, or the
  destination, and it never infers draft, ready, merged, or closed state. The UI
  says **Pull request** without claiming a lifecycle status.
- Existing automatic links are rechecked against the current feature context.
  Unrelated or unverified links are hidden, not deleted. **Show hidden → Restore**
  explicitly retains one if needed. User saves, custom titles, and restores are
  preserved, and a user-hidden link stays hidden even when it matches.
- Repository identity comes from bounded reads of local Git remote configuration.
  Discovery never runs a remote Git command or fetches ticket metadata.

## General links and share URLs

General links can be any bounded absolute HTTP(S) address. Path, query, port,
and fragment are preserved exactly, so a private share URL such as
`https://share.example.test:8443/review/abc?tab=links#evidence` round-trips
without losing meaningful components. The same holds for a bracketed IPv6
destination such as
`https://[2001:db8::42]:8443/review?tab=links#evidence`. Saving such a URL
stores it privately; it does not create, configure, or publish a share.

## Compatibility and deployment

The feature is additive. Companions advertise `first-mate-links-v1` on the
existing capability surfaces, feature snapshots gain an optional `links` array,
and older clients safely ignore it. Older companions keep working: Mac shows an
update explanation instead of pretending a save succeeded, and iOS and the web
client remain compatible with no new link-management interface of their own.

Full Mac link management requires the matching companion/Pi package, installed
and restarted separately. The signed Mac feed installs only the app; no server
cutover is performed by the app updater. The contextual discovery fix requires
companion 0.46.2b1 and its bundled Pi extension, with an additive, lossless saved-link
migration. Back up the database before the server update. See the companion
release notes for installation and verification details.

## Verification checklist

1. Open the synthetic demo (`-HerdrDemoMode`) and open **First Mate**. Confirm
   **Overview** leads with two pull requests and that the single general link
   does not appear there.
2. Open **Documents**. Confirm the same pull requests lead the tab and sit above
   the **Documents / Links** control, and that the existing document rows still
   open.
3. Switch to **Links**. Confirm pull requests lead the list, the general share
   link is separate, and the host, port, query, and fragment are visible.
4. Add a link with a custom port and query. Confirm it appears without clearing
   any other record, then **Hide** it, turn on **Show hidden**, and **Restore**
   it.
5. Use **Copy** and confirm the copied value matches the saved URL exactly. Do
   not use **Open** for synthetic destinations.
6. Switch to a feature with no links and confirm the empty states. Switch back
   and confirm the original documents and links are unchanged.
7. Against a companion without `first-mate-links-v1`, confirm the Add control
   explains the required update and no request is sent. After separately
   updating and restarting the companion, refresh and confirm saves work.
8. Run the shared `FirstMateLinksTests` and `FirstMateHTTPTests` suites on Mac
   and iOS, the Mac `FirstMateLinksPresentationTests` suite, and the
   `HerdrFirstMateLinksUITests` demo suite. Run
   `python3 scripts/check-public-source.py` before committing.

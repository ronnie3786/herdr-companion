# First Mate performance: complete read-path follow-up

Date: 2026-09-29. This is a new layer following `FINDINGS.md` and
`FINDINGS-2026-09-29-local-mac.md`; those earlier layers are unchanged.

The follow-up includes the previously deferred independent Overview loading and
prepares Mac 0.73.0-beta.1 (build 120) plus a separate companion 0.67.0b1 package.
The operator will assess the released update manually. No new synthetic timing
benchmark or manual stress test was run for this follow-up. The earlier layer's
measurements describe its earlier source revision, not this expanded change.

## Native read and presentation changes

- Chat loads directly and independently of the feature list and inspector.
- An advertised `first-mate-read-views-v1` capability enables versioned chat,
  Overview, and detail reads. An unchanged reply has no snapshot to decode or
  publish. The existing snapshot routes remain the fallback for old companions
  and a companion rolled back while a capability answer is still cached.
- A chat opens with the newest 60 conversation messages. **Load earlier messages**
  uses a feature-owned message cursor. Earlier pages merge without duplicate rows;
  overlapping latest-page updates keep loaded history. A disconnected new tail
  resets pagination rather than silently hiding a gap. A page contributes history
  without replacing newer feature, model, or verification state.
- Overview has its own snapshot, errors, and refresh task and can complete before
  chat. Agents, Documents, and Workflow request the full detail view when selected.
  Mutations invalidate inspector versions and wake its read; background chat polls
  do not replace or repeatedly reload the inspector. Full verification evidence is
  available in Overview.
- Chat polls every two seconds in a key window, ten seconds when inactive, and
  thirty seconds in the background. Activation wakes the read immediately.
  Inspector refreshes have a separate, slower cadence. The fleet remains on its
  existing independent ten-second cadence.
- Cold mention linking runs off the main actor. The complete attributed source and
  catalog identify the result; current unlinked text remains visible until the
  matching result is ready. Cancelled and superseded work cannot publish links for
  an old target. The existing bounded cache still covers repeated inputs.
- Bubble layout reuses measurements between sizing and placement and invalidates
  them when subviews change. Quantized width observation replaces the chat window's
  root GeometryReader while preserving its explicit column width. The earlier
  composer height fix remains.
- Transcript growth follows the newest message only when the reader is already at
  the bottom. Loading earlier history anchors the previously first displayed row.

## Companion implementation and safety findings

The companion exposes additive authenticated reads:

`GET /api/v1/first-mate/features/{id}/presentation`

The query accepts `view=chat|overview|details`, `messages=1...200` (default 60),
`before=<message ID>` for chat, and `if_version=<response version>`. Versions include
feature identity, view, bounds, cursor, ledger state, runtime metadata, and semantic
verification. A matching version yields `unchanged: true`; a changed reply retains
the native snapshot field names. A cursor is validated before conditional matching.
Runtime reads are bracketed by ledger checks so a concurrent write cannot attach a
new version to an older projection.

Chat and Overview use narrow SQL projections. Chat omits event history, and
Overview reads only four journal entries and no conversation. Document metadata
excludes internal handoff checkpoints in compact views; full details preserve the
complete records and their handoffs. Current coordinator session metadata and a
separate queued-work flag preserve model-control behavior even when queued work is
outside the displayed chat page. Legacy API routes retain their original shapes.

The `first-mate-verification-summary-v1` capability enables compact feature-list
verification. Summaries preserve the selected gate set and tested revisions needed
by the native Verified validation; counts replace heavier diagnostic arrays. Full
assessment details stay in the independent Overview response. No status-only green
path was introduced.

Read-only verification uses a bounded ten-second cache with one assessment flight
per feature. Evidence, inventory, selection, workspace identity, and Git state are
checked before reuse. A review found that repeated edits can keep exactly the same
Git porcelain status (`M path` or `?? path`), so dirty worktrees deliberately cannot
reuse the cache. Failed probes cannot reuse a prior green. Mutation and workflow
gate decisions remain uncached. The conditional board path can return unchanged
before building its bounded projection. Empty feature lists skip job accounting.

Successful JSON GET responses negotiate gzip, preserving authentication, no-store
headers, and uncompressed compatibility. Mutations, errors, and event streams do
not enter the new compression path.

## Delivery and compatibility

The Mac rendering, direct-opening, and independent inspector changes work against
older companions. Paged chat, smaller conditional replies, compact verification,
and server assessment reuse require companion 0.67.0b1. iOS, web, and Pi keep the
legacy endpoints and do not need coordinated client replacement.

The Mac update is delivered through the signed GitHub Releases feed. Its exact
source must pass Verify before artifact preparation and publication. The companion
wheel is a separate release with its source revision and SHA-256, fresh web assets,
and an isolated installed-package check. The Mac updater never installs it.
A companion rollout preserves the private configuration and state, uses a new
versioned Python runtime, and keeps the prior runtime and launcher for rollback.
No configuration or schema migration is required.

## Validation

Focused automated correctness checks cover version reuse, independent Overview,
pagination, mutation ordering, cancelled reads, async text identity, layout cache
invalidation, compact verification proof, cache expiry and concurrent readers,
Git/evidence invalidation, cursor ownership, compression negotiation, and legacy
contracts. Local verification completed with 187 focused server tests, 33 socket/API tests,
151 Mac tests across 14 suites, 50 final Mac checks across 6 suites after review refinements, and 74 iOS tests across 6 suites. A separate async
text/layout pass covered 38 tests and the chat-window render suite. Final CI is
required on the exact published source, including the full Mac, iOS, Python, web,
Pi, privacy, credential scan, and standalone-install matrix. These checks are
correctness evidence, not a new timing claim.

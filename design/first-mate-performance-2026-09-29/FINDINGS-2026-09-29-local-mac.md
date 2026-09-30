# First Mate performance: local Mac measurement and implementation layer

Date: 2026-09-29. This is a new layer, not a revision of `FINDINGS.md`.

## Result and source

The Mac changes remove timestamp-only UI publications, let conversation reads
bypass feature-list requests and superseded reads, move file-card matching out of
the view body, cache mention linking, and constrain redundant composer layout.
The companion optimization is a separate source change with a separate release
and rollout requirement. Neither component has been published or installed by
this investigation. Independent Overview loading remains deferred.

- Baseline: `ca75867d2d55180a9a213f1a745866f73abda59a`.
- Mac/shared-client implementation: `fcc2eca`.
- Companion implementation: `2c0bd55`, separate from the Mac commit on
  `codex/first-mate-performance`.

All measurements and tests ran on the local Mac, with synthetic fixtures. No
remote Mac or operator database was used. The existing working checkout was
preserved; implementation used an isolated checkout.

## Method and an important correction

The Mac harness mounts the production chat root in an actual `NSHostingView` and
`NSWindow`, at 1100 by 800 points. Its selected feature is paused, so the real
composer is visible. It contains 177 synthetic messages, 173 documents, and long
assistant replies. A separate text measurement uses 74 synthetic mention names.
The demo sidebar includes working indicators, so idle CPU is not a blank-window
or all-agents-idle measurement.

Each window phase performs 200 iterations with a 20 ms asynchronous wait. The
reported delay is elapsed time beyond that wait. Native input includes the
synchronous `NSTextView.insertText` call and verifies that all 200 characters reach
the draft. Draft edits also exercise multiline growth. Scrolling moves the native
scroll view in both directions. Synthetic polls arrive during each phase, and the
reply-arrival phase adds two new replies. This measures main-actor responsiveness,
not display-frame latency or physical keyboard input. CPU is process CPU time
divided by elapsed time; 100% is approximately one core.

The first pilot incorrectly marked the selected feature completed, which removes
the composer. Its draft-state results therefore were not typing measurements.
The visible-composer harness was corrected and run against a fresh export of the
baseline and against the candidate. Only those corrected results appear below.
Both use Debug builds on macOS 26.2 arm64, Xcode 26.2 (17C52). Timings are single
local runs, not production latency guarantees or machine-independent test limits.

## Corrected before and after

Window delay, milliseconds, 200 samples per phase:

| Phase | Before median | After median | Before p95 | After p95 | Before maximum | After maximum |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Idle with polls | 2.16 | 1.53 | 4.22 | 3.56 | 787.12 | 4.90 |
| Draft edits and multiline growth | 465.39 | 11.80 | 658.12 | 15.01 | 2479.38 | 237.59 |
| Scrolling | 2.11 | 1.49 | 4.43 | 27.52 | 1075.88 | 154.52 |
| Native text insertion | 447.21 | 10.88 | 505.83 | 13.76 | 1547.31 | 45.46 |
| New replies | 1.53 | 1.48 | 3.47 | 3.92 | 2610.90 | 106.57 |

Idle CPU fell from 38.16% to 16.61%; scroll CPU fell from 67.46% to 56.60%.
Continuous synthetic typing still used approximately one core in Debug. The
scroll p95 increased even though the longest stall fell substantially. Lazy row
creation, multiline growth, and reply insertion can still produce visible outliers.
These results support a large typing and idle improvement, not a claim that all
scroll frames now meet a 60 Hz budget.

Other measurements:

| Measurement | Before | After |
| --- | ---: | ---: |
| Cold selected snapshot available, mock list 600 ms and snapshot 100 ms | 710.47 ms | 105.40 ms |
| Switch while old snapshot request takes 800 ms | 1505.51 ms | 105.34 ms |
| List / snapshot / capability calls across the opening scenario | 3 / 3 / 3 | 0 / 3 / 1 |
| Publications from 10 otherwise identical snapshot polls | 10 | 0 |
| Raw file-card scan median, five samples | 462.99 ms | 135.09 ms |
| Mention linking, 20 identical blocks, median of five batches | 61.42 ms | 11.91 ms |

Opening numbers end when the requested snapshot is available. They exclude live
network/server latency and complete first-frame rendering. Mention measurements
include cache reuse and do not imply an equivalent cold-scan improvement.

## What the evidence changed

1. **Timestamp churn was real but was not the typing cause.** Unchanged assessment
   `computedAt` values and healthy heartbeat `lastSuccessAt` values caused observable
   publications. Semantic comparisons suppress those writes. Raw verification
   timestamps still advance a private ordering fence, so a delayed green verdict
   cannot overwrite a newer failure. Changed verdicts, evidence, event cursors,
   transcript content, and unhealthy heartbeat information remain observable.

2. **Opening waited on work it did not need.** Chat windows already have the fleet
   list. Their selected conversation now loads directly, with capability probes
   reused for up to 60 seconds. Selection wakes cancel the previous request and
   start the new read immediately. Context, request identity, and cancellation
   guards reject late responses even if transport cancellation is ignored. The
   main workspace refreshes its list independently every ten seconds and its
   selected conversation every two seconds.

3. **Text scanning contributed to redraw stalls.** File-card matching bridged each
   reply once per document search. It now bridges once per reply, precomputes title
   boundaries, and runs outside the main actor when content changes. Cancellation
   and full input identity prevent cross-conversation or stale-card publication.
   Mention results use a bounded cache keyed by the full attributed text and
   catalog, including destinations and status. Unicode, literal matching, existing
   links, formatting, edits of equal length, renamed documents, and removals are
   covered by regression tests.

4. **Layout was a separate, large typing cost.** With the composer visible,
   sampling showed repeated `GeometryReaderLayout.placeSubviews`, stack sizing,
   and flexible-frame measurements. Poll suppression and caching alone still
   measured 476 ms median for draft edits. Constraining the chat column to the
   width already known by its geometry reduced native input to 117 ms median.
   Keeping the First Mate composer at its intrinsic vertical size reduced it to
   11 ms. The editor still grows to five visible lines and scrolls longer drafts.
   The adaptive model controls, bubble layout, and inspector behavior were retained.
   A three-second sample was taken during the intermediate width-only experiment;
   no profiler was running during the final measurement.

## Separate companion finding

The original full-snapshot hypothesis was incomplete. Verification performed two
unnecessary full reads, but worker policy selection also called `_stage_key` once
per assignment. With 50 assignments using implicit model policy, a journal-only
snapshot materialized the full history 52 times.

The separate companion change uses an existing feature-scoped assignment query
for verification and a feature/visit-scoped stage-key query for policy lookup.
It does not cache verdicts, alter schema, or change request/response shapes.

The local SQLite fixture contains 50 assignments, 20,000 telemetry events and
2,000 journal events. These are medians of five runtime-method calls including JSON
encoding, not HTTP timings:

| Request | Before | After | Full snapshot reads, before / after |
| --- | ---: | ---: | ---: |
| Feature list | 296.34 ms | 47.53 ms | 2 / 0 |
| Journal snapshot | 6009.18 ms | 69.93 ms | 52 / 0 |
| Board | 284.98 ms | 50.19 ms | 2 / 0 |

The journal response remained 2,958,702 bytes. Its one intentional journal-only
projection remains. Tests verify verdicts, worker model selection, telemetry
exclusion, missing-visit behavior, and feature ownership of the targeted query.

## Verification and delivery boundaries

- Python: all 2,252 tests passed, one skipped. The installed-wheel verification
  passed resources, CLI, authenticated API, web assets, extension, isolated state,
  and clean shutdown checks.
- Mac: the full unit suite passed 2,992 tests before the final layout refinements.
  Subsequent focused checks passed on the final shared/polling changes, followed
  by 38 layout/navigation/editor tests and 45 async, optimistic-send, voice, and
  HUD tests on the final layout source. All three final measurement tests passed.
- iOS: 100 relevant shared/native tests passed on the local simulator after the
  shared changes.
- Web: 36 contract tests and 387 frontend tests passed; the production build passed.
- Pi extension: 93 tests passed.
- Narrow (700 pt), intermediate (1000 pt), and wide (1440 pt) chat renders passed.
  Narrow and wide output was inspected for composer and column placement.
- Public-source privacy scans and whitespace checks passed before source commits.
  No captured conversations, filled configurations, or deployment identities are
  included in these fixtures or this layer.

The Mac source can be released independently through the existing signed GitHub
Releases feed after the normal exact-source Verify and release gates. It works
with the existing companion API. The companion change requires its own package
release and explicitly authorized server rollout, with the installed-wheel and
compatibility checks repeated for that release artifact. Updating the Mac app
does not install or restart the companion. No live rollout or remote testing was
performed here.

## Repeating the measurements

From the checkout root, use a new result path:

```sh
python3 design/first-mate-performance-2026-09-29/measure/local_mac.py \
  --derived-data /tmp/herdr-first-mate-measurement \
  --result /tmp/herdr-first-mate-measurement.xcresult
```

The runner enables the otherwise opt-in `FirstMatePerformanceMeasurements` tests.
Use `--skip-build` only for an already-built matching source revision. To compare
an earlier revision, export that revision and copy only the measurement test,
synthetic transport test support, and runner into the export. Run before and after
sequentially, with the same configuration and fixture. Avoid other heavy work on
the measuring Mac. Timings are printed with the `FM_PERF` prefix.

With the repository's Python 3.11+ environment:

```sh
python3 design/first-mate-performance-2026-09-29/measure/synthetic_server.py
```

The server runner creates and destroys its own temporary Git/SQLite fixture.
Private raw measurement logs and Xcode result bundles were retained outside Git;
the corrected baseline, intrinsic-layout final, and server before/after logs are
the evidence behind the tables above.

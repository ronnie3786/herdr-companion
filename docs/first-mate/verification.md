# First Mate delivery verification

Verified on 2026-09-13 in the isolated `codex/first-mate` worktree. The implementation adds a native Mac workspace and reusable web inspector to the existing companion service. Production app and server installations were preserved.

## Automated checks

| Surface | Result |
| --- | --- |
| Full Python suite | 927 tests passed, 1 skipped |
| Focused Mac First Mate and navigation tests | 43 passed; app built and signature verified |
| Existing web client suite | 362 tests across 37 files passed; production build passed |
| First Mate web regressions | 11 passed |
| Pi extension package suite | 50 passed; 7 focused First Mate checks also rerun after runtime changes |
| Installed server wheel | Fresh isolated install passed resource discovery, authenticated APIs, static assets and shutdown checks |
| Public source guard and staged whitespace check | Passed |

The Python suite includes detached-process integration and failure injection for durable dispatch, restart, exact session ownership, bounded recovery, human gates, seven reviewers, revision-bound review, nested delegation and fresh-session handoffs. Those tests use a synthetic RPC executable for deterministic model decisions.

## Real Pi verification

Separate bounded runs used the installed Pi provider against synthetic projects:

- A planner returned attributed evidence and the feature paused for human direction. A restarted manager resumed the same coordinator conversation and answered a status question without starting another stage.
- A lead delegated two reviewers, yielded without polling, resumed the same saved session, collected both documents and reported its result. All three assignments completed before the stage paused.
- The authenticated HTTP API started a tiny implementation in an isolated Git worktree. Three independent tests passed. The feature paused, a new human message authorized review, and a separate read-only reviewer inspected the exact implementation commit. Both stages retained attributed documents; the original checkout stayed unchanged.

These runs validate orchestration and evidence plumbing. They do not establish model quality for arbitrary large features. Private execution records, session identities and artifact hashes remain in the ignored build directory.

## Interface and media

Native and web checks covered light/dark presentation, separate features, durable chat acknowledgements, seven-reviewer disclosure, multiple documents, exact producing sessions, retained predecessor history and earlier transcript pages.

The explainer contains three finished reels of approximately 26, 28 and 29 seconds. Each uses edited captures of the implemented Mac UI with synthetic demonstration data, generated narration, English captions and a transcript. All videos decode end to end. Private hosting was verified for full files, byte-range seeking and caption MIME types; browser playback and timeline seeking also passed.

## Delivery and initial boundaries

The ignored `build/first-mate-delivery` directory contains a separately identified Mac preview app, a demo launcher and a verified server wheel. The demo launcher never starts models. Normal operation needs the matching server revision and the operator's private Pi configuration; follow the installation commands in the main README.

- Each feature belongs to one companion host. A merged multi-host feature list is outside this initial version.
- The graph displays recorded workflow visits and their agents/documents. It is not a dependency editor.
- Managed delegation must use the scoped Pi tools. Arbitrary independently launched processes are not automatically adopted.
- Handoffs stop the predecessor at its saved checkpoint before the successor starts. Saved history is retained, and the successor must acknowledge the checkpoint before editing.
- Very long feature histories can still accumulate human directives in coordinator recovery context. Incremental decision summarization remains a future improvement.
- Session transcripts are paginated. Feature detail exposes the newest 1,000 session metadata records with a truncation flag; older records remain retained in the host ledger.

See [the runtime guide](runtime.md) for configuration, ownership boundaries and recovery behavior, [Mac chat parity and its release checklist](chat-parity.md), and [the implementation contract](build-contract.md) for the shared API and human checkpoints.

## First Mate response feedback (issue #42)

Ratings, reusable reasons, and notes are stored only in the owning companion's
private `first-mate.sqlite3`; the Mac keeps an in-memory cache. The final gate
completes this table on the delivered revision, recording exact-source
automated results separately from synthetic rendered-UI and connected-app
evidence. A row is complete only when it records the delivered commit SHA, its
**Tested revision** matches that revision, the exact command(s) appear in the
protocol, and its **Evidence** cell names the captured log, artifact, or
screenshot; a result from another revision is not evidence. Rendered-UI rows
require synthetic screenshots or accessibility captures, and demo-memory
results never substitute for the connected-app persistence row. The Verify
workflow's Mac job runs `herdr-harness-macTests` only, so the rendered UI test
and the connected-app checklist below are additional required gate items.

An external SHA-keyed validation record is the preferred home for the raw
evidence. Write it under the ignored build directory as
`build/first-mate-feedback/validation-<full-commit-sha>.md` (or keep the same
name in the private release workspace) with one section per gate row: the exact
command, its exit status, and the paths of the captured logs, screenshots, and
accessibility snapshots. The table's **Evidence** cells then link that record.
The rendered UI suite already emits its artifacts, so run it with
`-resultBundlePath build/first-mate-feedback/rendered-<full-commit-sha>.xcresult`
to keep every capture bound to the tested revision; the `.xcresult` retains the
PNG screenshots and the accessibility-tree attachments even when `/tmp` is not
writable.

| Gate item | Exact-source protocol | Tested revision | Result | Evidence |
| --- | --- | --- | --- | --- |
| Companion store, HTTP, runtime | `.venv/bin/python -m unittest tests.test_first_mate_feedback tests.test_first_mate_http tests.test_first_mate_runtime` (the HTTP module includes the disposable companion close/reopen feedback check) | Pending final gate | Pending final gate | Pending final gate |
| Shared native unit tests (Mac and iOS) | Mac: `xcodebuild -project herdr-harness-mac/herdr-harness-mac.xcodeproj -scheme herdr-harness-mac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:herdr-harness-macTests`. iOS: the `herdr-harness-iosTests` target with the same `HerdrFirstMateSharedTests`; it must not be skipped when shared sources change. | Pending final gate | Pending final gate | Pending final gate |
| Synthetic rendered interactions | `xcodebuild -project herdr-harness-mac/herdr-harness-mac.xcodeproj -scheme herdr-harness-mac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -resultBundlePath build/first-mate-feedback/rendered-<full-commit-sha>.xcresult test -only-testing:herdr-harness-macUITests/HerdrFirstMateFeedbackUITests` in demo mode only. The suite writes PNG screenshots to `/tmp/herdr-first-mate-feedback-screens` and attaches each screenshot plus its accessibility tree to the result bundle. This exercises the rendered rating controls, editor, custom reasons, note, Save/Cancel, cancel-and-reopen catalog behavior, and Remove rating against in-memory synthetic data. | Pending final gate | Pending final gate | Pending final gate |
| Historical, closed, and archived responses | In the synthetic demo, rate an older response, a checkpoint summary, and a response inside a closed or archived feature. Confirm the controls and saved states render, the editor stays pinned to the rated message, and no feature status, revision, workflow event, or queued message changes. | Pending final gate | Pending final gate | Pending final gate |
| Failure and retry behavior | Shared native tests force delayed loads, delayed and failed saves, revision conflicts for the editor, thumbs up, and Remove rating, and failed/slow category reads. Confirm the attempted payload and draft survive and that only the explicit reload actions recover conflicts. | Pending final gate | Pending final gate | Pending final gate |
| Transient capability loss | Shared native test `FirstMateFeedbackTests/transientCapabilityOutagePreservesDraft` fails a save, then fails the capability refresh, and confirms the attempted draft, save error, and connection guidance survive with no upgrade notice; a recovered refresh restores writing and retries the exact request identity. Run it with the shared native unit command above (Mac and iOS). Confirm the connection notice, retained note, and **Retry connection** render in the synthetic presentation tests `FirstMateFeedbackPresentationTests/transientCapabilityOutage` and `FirstMateFeedbackPresentationTests/failedSaveThenCapabilityOutage`. | Pending final gate | Pending final gate | Pending final gate |
| Alternate-host isolation | Against two disposable companions with duplicate synthetic feature and message labels, save distinct ratings, switch hosts, and reconnect. Confirm each connection restores only its own feedback, an open editor dismisses instead of retargeting, and no save reaches the other host. | Pending final gate | Pending final gate | Pending final gate |
| Connected-app persistence and relaunch | With a disposable on-disk companion state and synthetic features, save ratings, reasons, a custom category, and a multiline note; restart the companion; relaunch the Mac app and reconnect; confirm the exact values return; then inspect `first-mate.sqlite3` read-only with the query in [response feedback](response-feedback.md). The automated HTTP close/reopen check above is the companion-side prerequisite; it never substitutes for the Mac relaunch. No production data, host, or installation is used. | Pending final gate | Pending final gate | Pending final gate |
| Public source guard | `scripts/check-public-source.py` plus the staged whitespace check. | Pending final gate | Pending final gate | Pending final gate |

The synthetic demo stores feedback in memory only and is not connected-app
persistence evidence. The automated HTTP close/reopen check proves companion
storage survives a restart at the API boundary, not the Mac relaunch half.
Generated screenshots and layout renders are presentation evidence, not
installed-app verification.

## First Mate gate verification (issue #68)

The verification feature adds a companion-side coverage assessment, the
worker-scoped `fm_record_verification` tool, additive API fields, and a shared
native/web Verification summary. The final gate completes this table on the
delivered revision, recording exact-source automated results separately from
rendered-UI and connected-app evidence. A row is complete only when it records
the delivered commit SHA, its **Tested revision** matches that revision, the
exact command(s) appear in the protocol, and its **Evidence** cell names the
captured log, artifact, or screenshot; a result from another revision is not
evidence. Rendered rows require the synthetic result bundle below, and demo
renders or in-memory fixtures never substitute for connected-app persistence.
All fixtures are synthetic; no production companion, host, or data is used.

| Gate item | Exact-source protocol | Tested revision | Result | Evidence |
| --- | --- | --- | --- | --- |
| Coverage evaluator rules | `.venv/bin/python -m unittest tests.test_first_mate_verification` (deterministic six-to-four omission, complete-coverage recovery, never-run suite, duplicate names, incomplete inventory, unmapped path, stale revision, interrupted run, failure supersession, invalid payloads) | Pending final gate | Pending final gate | Pending final gate |
| Store, runtime, HTTP, and CLI integration | `.venv/bin/python -m unittest tests.test_first_mate_verification_runtime tests.test_first_mate_store tests.test_first_mate_runtime tests.test_first_mate_http tests.test_first_mate_board tests.test_first_mate_cli` (temporary Git repositories exercise restart, handoff, later-stage, and isolated-worktree persistence) | Pending final gate | Pending final gate | Pending final gate |
| Pi extension typed contract | `npm --prefix pi-semantic-bridge test` (includes `verification recording is worker-scoped and carries the exact gate contract`) | Pending final gate | Pending final gate | Pending final gate |
| Browser Overview | `node --test tests/first_mate_web.test.cjs` (verified, partial, failed, unknown, absent, long-list, and offline last-reported rendering) | Pending final gate | Pending final gate | Pending final gate |
| Shared native unit tests (Mac and iOS) | Mac: `xcodebuild -project herdr-harness-mac/herdr-harness-mac.xcodeproj -scheme herdr-harness-mac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:herdr-harness-macTests`. iOS: the `herdr-harness-iosTests` target with the same `HerdrFirstMateSharedTests`; it must not be skipped when shared sources change. | Pending final gate | Pending final gate | Pending final gate |
| Rendered verification summary | `xcodebuild -project herdr-harness-mac/herdr-harness-mac.xcodeproj -scheme herdr-harness-mac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -resultBundlePath build/first-mate-verification/rendered-<full-commit-sha>.xcresult test -only-testing:herdr-harness-macTests/FirstMateVerificationRenderTests`. The suite runs inside the Mac unit target and writes light/dark PNGs for verified, partial, failed, last-reported, and long-identifier states; the result bundle retains the screenshots and accessibility attachments. | Pending final gate | Pending final gate | Pending final gate |
| Connected Mac, iOS, and browser Overview | With a disposable companion and synthetic data, open a feature at each verdict and confirm the Verification section shows the tested revision and package-qualified gate set with named missing, previously passing dropped, failing, and stale suites; a long gate set discloses its remainder; the section stays visually separate from the workflow badge. | Pending final gate | Pending final gate | Pending final gate |
| Connected-app persistence and downgrade | Record complete passing evidence, restart the companion, relaunch the client, and confirm the verdict and gate set return; advance the synthetic source revision and confirm the older green becomes stale with its gate set retained instead of staying verified; record a later failure and confirm selecting the earlier passing run cannot hide it. | Pending final gate | Pending final gate | Pending final gate |
| Legacy and stale-client compatibility | Against a companion that omits `first-mate-verification-v1`, confirm **Verification unavailable** with no green promotion and no invented gate set; then reconnect a client that previously cached a verified state and confirm a delayed, partial, or malformed response cannot resurrect it. | Pending final gate | Pending final gate | Pending final gate |
| Public source guard and staged whitespace | `scripts/check-public-source.py` plus `git diff --check`. | Pending final gate | Pending final gate | Pending final gate |

The Python, Pi, and web rows run inside the repository Verify workflow's full
`python -m unittest discover -s tests`, `npm --prefix pi-semantic-bridge test`,
and `node --test tests/first_mate_web.test.cjs` jobs; the shared native and
rendered rows run inside the Mac and iOS unit targets. The rendered row emits
synthetic screenshots and accessibility attachments, and the connected-app rows
are additional required gate items, not substitutes for the automated matrix.
At documentation time the focused checks
`python3 -m unittest tests.test_agent_docs`,
`python3 scripts/check-public-source.py`, and `git diff --check` passed locally;
they are documentation checks and do not replace the exact-revision gate above.
No row above records a result for another revision.

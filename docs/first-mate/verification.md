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
private `first-mate.sqlite3`; the Mac keeps an in-memory cache. Exact-source
automated results are recorded separately from synthetic rendered-UI and
connected-app evidence. The rows below stay explicitly pending until the final
gate executes them on the reviewed revision; a result is valid only when its
tested revision matches the delivered source.

| Surface | Protocol | Result |
| --- | --- | --- |
| Companion store, HTTP, runtime | `.venv/bin/python -m unittest tests.test_first_mate_feedback tests.test_first_mate_http tests.test_first_mate_runtime` | Pending final gate |
| Shared native unit tests | Mac: `xcodebuild -project herdr-harness-mac/herdr-harness-mac.xcodeproj -scheme herdr-harness-mac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:herdr-harness-macTests`. iOS: the `herdr-harness-ios` test target with the same `HerdrFirstMateSharedTests`; it must not be skipped when shared sources change. | Pending final gate |
| Synthetic rendered interactions | `xcodebuild -project herdr-harness-mac/herdr-harness-mac.xcodeproj -scheme herdr-harness-mac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:herdr-harness-macUITests/HerdrFirstMateFeedbackUITests` in demo mode only. This exercises the rendered rating controls, editor, custom reasons, note, Save/Cancel, and Remove rating against in-memory synthetic data. | Pending final gate |
| Failure and retry behavior | Shared native tests force delayed loads, delayed and failed saves, revision conflicts for the editor, thumbs up, and Remove rating, and failed/slow category reads. Confirm the attempted payload and draft survive and that only the explicit reload actions recover conflicts. | Pending final gate |
| Connected-app persistence | With a disposable on-disk companion state and synthetic features, save ratings, reasons, a custom category, and a multiline note; restart the companion; relaunch the Mac app and reconnect; confirm the exact values return; then inspect `first-mate.sqlite3` read-only with the query in [response feedback](response-feedback.md). No production data, host, or installation is used. | Pending final gate |
| Public source guard | `scripts/check-public-source.py` plus the staged whitespace check. | Pending final gate |

The synthetic demo stores feedback in memory only and is not connected-app
persistence evidence. Generated screenshots and layout renders are presentation
evidence, not installed-app verification.

# Code Factory: from an in-app report to a signed release

Code Factory turns a bug report or feature request filed from the Mac app into a
GitHub issue, a planned and implemented pull request, an Astra code review, a squash
merge, and a signed macOS preview release, without a person driving each step. It is an
operator-run daemon plus a Tailscale-reachable dashboard. Nothing in it replaces the
authentication, privacy, signing, or CI gates already described in
[docs/macos-releases.md](macos-releases.md) and [AGENTS.md](../AGENTS.md).

This is an experimental personal automation. Read the safety section before enabling it.

## What happens, end to end

1. **Report from the Mac app.** Help → **Report a Bug or Request a Feature…** (⌘⌥F), or
   Settings → General → **Feedback**. Choose Bug or Feature request, write the final title and
   description, attach screenshots or documents (file picker, drag and drop, or ⌘V for an image),
   and check **Included details** to see the environment fields that accompany the report. The
   optional **Smart input** box can draft both fields from plain English with one bounded,
   tool-free `issue-report-draft-v1` run (**Draft with AI**) or transcribe one inline recording
   with the selected companion's configured transcription service; the generated fields stay
   editable and neither action files anything. Only **File report** publishes the final edited
   title and description verbatim. Leave **Start the automated fix pipeline** on to add the
   `herdr-autofix` label. The report files through this Mac's companion, or the first connected
   companion if this Mac's is unavailable.
2. **The companion server files the issue.** The app posts to `/api/v1/issue-reports`.
   The server uses your authenticated `gh` CLI to create a public GitHub issue with the
   verbatim text, links to the attachments, and an environment table. Attachments are
   uploaded as assets on a rolling release tagged `issue-attachments` so images render
   inline in the issue. Labels: `herdr-app-report`, `bug` or `enhancement`, and
   `herdr-autofix` when requested.
3. **The daemon picks it up.** `herdr-code-factory run` polls open issues with the trigger
   label. Only issues authored by an allow-listed GitHub login are accepted, because the
   repository is public and issue text is untrusted input.
4. **Isolated worktree.** Each issue gets `codefactory/issue-<n>` in its own git worktree
   under the configured worktree root, based on `origin/main`. Issues never share a
   checkout, and your working checkout is never touched.
5. **Astra plans.** A headless Pi session on `openai-codex/gpt-6-astra` reads the issue and
   the attachments (images included), inspects the repository read-only, and returns a
   bounded JSON plan. The plan carries stable requirement IDs that preserve excerpts from
   the original request, observable outcomes, required evidence, and explicit confirmed or
   unresolved assumptions, plus acceptance criteria, at most four sequential tasks with
   owned paths and tests, documentation obligations, and attachment descriptions. Astra
   resolves ordinary low- and medium-risk ambiguity from repository evidence, established
   best practices, the safest reversible choice, and the ideal user experience. Those choices
   are recorded as confirmed inferred assumptions instead of becoming operator questions.
   Human input is reserved for high-risk authority boundaries involving security or privacy,
   credentials or access, destructive or irreversible data loss, money or legal/compliance
   obligations, or external production impact when no safe reversible path exists. At that
   point Astra asks one specific question, the issue is marked **blocked**, and Message Me
   alerts the operator with a link to the Code Factory dashboard. On **Retry**, planning
   refreshes the issue body and recent replies from allow-listed operators while excluding
   Code Factory's own comments, so an answer becomes part of the next plan.
6. **DeepSeek implements.** For each task a fresh Pi session on
   `ollama-cloud/deepseek-v4.1-flash:cloud` with thinking `max` implements the task in the
   worktree, writes tests without running incremental suites, and commits. The complete
   candidate is exercised by the final Verify gate. The daemon also runs the public-source
   privacy check and gives DeepSeek one chance to fix findings.
7. **Pull request and CI.** The daemon pushes the branch, opens a PR that references the
   issue (`Refs #n`, never `Closes`, so the issue stays open until released), and waits
   for the **Verify** workflow on the exact head commit.
8. **Astra reviews.** Astra receives the bounded original issue body and the downloaded
   image attachments again, independently derives observable outcomes, and compares the
   request with both the plan and diff. Each planned requirement must have a unique review
   assessment with concrete evidence. The review also records whether the plan narrowed
   the request and a counterexample using another valid configuration (or a justified
   not-applicable result). CI/plan agreement alone is not evidence, and code/test evidence
   is not described as installed or deployed UI verification. Missing, unmet, unverified,
   narrowed, unresolved, stale, or unposted approval data blocks merge. Ordinary reversible
   findings go to a reviser with Astra's recommended best-practice fix; review asks a human
   only for the same high-risk authority boundaries used during planning. A narrowing finding
   starts a fresh plan with the original request and bounded prior review evidence (requirement
   assessments, narrowing explanation, blocking findings, and human question) as explicitly
   delimited untrusted context. The planner must account for rejected assumptions and any
   existing branch implementation; completed task progress and prior approval are not reused,
   while the review-round ledger remains intact. The corrected plan is posted through the
   existing issue-comment mechanism. Because the same GitHub account authors and reviews the PR,
   the review is posted as a comment-type review
   with an explicit **approve** or **request changes** verdict in its text.
9. **Fresh revisions.** A red CI run first gets one automatic re-run of only its failed
   jobs for that head commit. A second failure on the same head goes to a new DeepSeek
   revision session, which commits and pushes. Astra implementation findings go to a
   revision session; a rejected/narrowed plan returns to planning, and only high-risk authority
   questions block for an issue-description decision instead of using a safe reversible fix.
   Astra's requested-change loop is bounded by
   `max_review_rounds`, while repeated CI failures are bounded separately by
   `max_ci_failures`. Exhausting either blocks the issue for a human with
   `review_rounds_exhausted` or `ci_failures_exhausted`, respectively.
   Retrying `ci_failures_exhausted` is a supervisory recovery action: it captures the
   latest failed log, grants one fresh bounded CI budget, and starts the reviser directly.
   Retrying `review_rounds_exhausted` likewise grants one fresh bounded review budget and
   starts the reviser with Astra's latest feedback. Both recoveries remain bounded, so a
   reviser that cannot produce a working change blocks again instead of creating an
   unlimited retry loop.
10. **Merge and cleanup.** On approval the PR is squash-merged with its remote branch
    deleted, and the worktree and local branch are removed immediately. The dashboard
    shows a checkmark once the worktree is gone. If a request is instead delivered by a
    consolidated or replacement PR, the poller follows GitHub's authoritative
    issue-closing relationship, replaces the stale per-issue PR link, and marks the
    dashboard request done. This also repairs older blocked or skipped ledger entries;
    it never infers delivery from a closed issue alone.
11. **Release.** Merged issues wait for the next release batch. A DeepSeek session in a
    fresh worktree runs `scripts/release-macos.py bump` (patch for bug-only batches,
    minor when a feature is included, on the configured channel), writes the release
    notes under `release/notes/`, and commits. The daemon validates the commit, pushes
    `main`, waits for Verify on that commit, then runs the existing `prepare` and
    `publish` steps with your private configuration. Each included issue gets a comment
    with the released version, the `released` label, and is closed.

## Setup

### Requirements on the publishing Mac

- The companion server package built from a revision that advertises
  `issue-reports-v1` (`GET /api/v1` lists it), installed and running as usual.
- `gh` authenticated with `repo` and `workflow` scopes for the repository.
- Pi with the `openai-codex` login (for Astra) and an `ollama-cloud` provider entry for
  DeepSeek. Ollama Cloud reads `OLLAMA_API_KEY`; a login shell may define it, but a
  daemon does not inherit your shell. Provide it through the private configuration:

  ```toml
  [environment]
  OLLAMA_API_KEY = { file = "~/.config/herdr-companion/secrets/ollama-api-key" }
  ```

- A git checkout of the repository whose `origin` is the GitHub repository. The daemon
  only creates and removes worktrees from it; it does not modify its working tree.
- The Message Me skill installed at
  `~/.codex/skills/message-me/scripts/message_me.py`. A missing or failed notification is
  recorded as a warning and does not change the feature's blocked state.
- For releases: the `[deployment.macos_release]` settings, Keychain access for the
  Sparkle key, and the Sparkle tools, exactly as in the release guide. Run one manual
  `prepare` on this Mac first so Keychain prompts are answered interactively.

### Configuration

Add a `[code_factory]` table to the private TOML (see `config.example.toml`). The
defaults are sensible for a single-operator repository:

```toml
[code_factory]
repository = "YOUR-OWNER/YOUR-REPOSITORY"
checkout = "~/projects/your-checkout"
allowed_authors = "your-github-login"
dashboard_host = "127.0.0.1" # Or "tailscale" for plain HTTP on the tailnet address.
dashboard_port = 9097
dashboard_token = { file = "~/.config/herdr-companion/secrets/code-factory-token" }
dashboard_link = "https://factory.example.invalid:9097/" # Canonical private URL for Message Me.
release_enabled = true
release_channel = "preview"
```

`dashboard_host` is `127.0.0.1` for the HTTPS setup below, or `"tailscale"` to bind this
machine's Tailscale IPv4 address directly (fallback: loopback). Every dashboard API call requires the bearer token when
`dashboard_token` is set; the page asks for it once and stores it in the browser.
The dashboard answers only for its own address (IP literals, `localhost`, the configured
host name, or a tailnet MagicDNS name when fronted by `tailscale serve`), refuses
cross-site browser requests, accepts `POST` bodies only as `application/json`, cannot be
framed, and closes idle connections after 30 s. Its address is recorded in the private
ledger only; issue comments never link to it.

`dashboard_link` is optional. Set it when Tailscale Serve fronts a loopback-bound
dashboard so Message Me can open the dashboard from another device. When it is omitted,
the alert uses the dashboard's bind URL. Dashboard links are sent only through the
private Message Me alert and never appear in GitHub comments.

### Check the installation

```sh
herdr-code-factory --config ~/.config/herdr-companion/config.toml --machine desktop doctor --fix
```

`doctor` verifies the repository, checkout, `gh` login, labels (`--fix` creates
`herdr-autofix`, `herdr-app-report`, and `released`), the Pi binary and both models,
the Ollama key, release settings, the dashboard bind address, and free disk space under
the worktree root.

### Run it

Interactively:

```sh
herdr-code-factory --config ~/.config/herdr-companion/config.toml --machine desktop run
```

As a LaunchAgent (replace the paths; use the installed runtime's `herdr-code-factory`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>org.example.herdr-code-factory</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/your-username/Library/Application Support/Herdr/Backend/current/venv/bin/herdr-code-factory</string>
    <string>--config</string><string>/Users/your-username/.config/herdr-companion/config.toml</string>
    <string>--machine</string><string>desktop</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>/Users/your-username/Library/Logs/herdr-code-factory.log</string>
  <key>StandardErrorPath</key><string>/Users/your-username/Library/Logs/herdr-code-factory.err.log</string>
</dict>
</plist>
```

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.example.herdr-code-factory.plist
```

Because release preparation signs with Keychain items, the daemon must run in your
logged-in GUI session (a LaunchAgent, not a LaunchDaemon).

For HTTPS on the tailnet, `tailscale serve --bg --https=9097 http://127.0.0.1:9097`
can front the dashboard when it is bound to loopback.

## Dashboard

The recommended setup binds the dashboard to loopback and lets Tailscale Serve
publish it over HTTPS to your tailnet only (Tailscale cannot proxy to the node's own
tailnet address, so the backend must be loopback):

```sh
tailscale serve --bg --https=9097 http://127.0.0.1:9097
```

Then open `https://<machine>.<tailnet>.ts.net:9097/` from any device on your tailnet.
With `dashboard_host = "tailscale"` instead, the same page is served as plain HTTP on the
machine's tailnet address. Either way it shows:

- stat tiles for active, blocked, failed, released, done issues and worktrees pending
  cleanup;
- one card per issue with kind, status, an eleven-step stage stepper, PR link, review
  round, CI status, released version, and a worktree-cleaned checkmark;
- a detail drawer with the plan summary, the blocked reason or error, every Pi session
  (role, model, thinking level, duration, cost), and the full event log;
- the release log with included issues and links.

Actions: **Retry** a blocked or failed issue at its current stage. A retry blocked on a
human question first refreshes the GitHub issue snapshot and returns to fresh planning; if the
refresh fails, the issue stays blocked. Other retries resume their current stage. **Skip** it (removes
the worktree and the trigger label; a running issue has its session cancelled first and
its worktree removed once the worker has stopped), **Clean up** a leftover worktree, and
**Release now** to start a batch immediately. The same operations exist on the command
line:

```sh
herdr-code-factory status
herdr-code-factory status --issue 42
herdr-code-factory action 42 retry
herdr-code-factory enqueue 42
herdr-code-factory release-now
herdr-code-factory cleanup
```

Only one process drives the pipeline at a time. `run` holds a daemon lock for its
lifetime; `once`, `enqueue` (without `--queue-only`), `action`, `release-now` and
`cleanup` refuse to start while it is held and name the holding process, so a cron
entry or a second terminal never runs a stage in a worktree the daemon is using. Use
the dashboard while the daemon runs, or `enqueue --queue-only` to record an issue for
its next poll. `action N retry` processes the issue immediately on the command line.
Re-enqueueing a skipped issue whose worktree was removed restarts implementation from
the saved plan (or re-plans); once a pull request exists it is refused, since the
branch history cannot be rebuilt.

## Safety and limits

- **Trigger gate.** Only open issues carrying the trigger label and authored by an
  allow-listed login are processed. Removing the label or closing the issue stops it.
- **Untrusted input and anchored requirements.** Issue text and attachments are treated as
  data. The bounded verbatim issue body is supplied to planning, implementation, revision,
  and review, but charters forbid following embedded instructions. Plans retain stable
  requirement IDs, source excerpts, outcomes, evidence, and explicit assumptions. Reviewer
  sessions also receive downloaded images and must compare the original request
  independently with the plan. Stored plans are fully revalidated before implementation,
  revision, review approval, and merge; legacy or malformed plans return to planning before
  an implementation worker runs, with obsolete task progress cleared. Planner and reviewer
  sessions are read-only; the daemon
  resets the worktree if one leaves changes behind.
- **Bounded automation.** At most four tasks per plan, a bounded number of review
  rounds and, separately, a bounded number of CI failures (each head commit gets one
  automatic re-run of its failed jobs before a CI failure counts against that bound), one
  release at a time, session timeouts, and a CI wait limit. Anything outside those bounds
  stops as **blocked** with the reason on the issue and the dashboard.
- **Sessions run as the operator.** Pi sessions are not sandboxed: they run with the
  daemon's user and environment (minus `HERDR_*` settings and GitHub tokens such as
  `GH_TOKEN`/`GITHUB_TOKEN`) and, for implementer roles, a shell tool. The daemon
  itself performs every push, `gh` call and merge, runs its git commands with
  repository hooks disabled, and on a session timeout terminates the session's whole
  process group.
- **Release process groups.** Release `prepare` and `publish` commands run in their
  own process group and are terminated as a whole on timeout or after a bounded
  `stop()` gives up waiting, so build workers such as `swift-frontend` cannot outlive
  them as orphans.
- **Existing gates stay.** The public-source privacy check runs before every push. CI
  must be green on the exact commit before merge and again before release preparation.
  The release script keeps its signing, notarization, feed, and publisher-lock checks.
- **Server code changes.** A merged fix that touches the companion server is released
  only as a Mac app update by this pipeline. Publish the companion package separately,
  as documented in [herdr_harness/README.md](../herdr_harness/README.md); the Mac
  updater never installs server packages.
- **Public repository.** Reports, attachments, plans, review comments, and release notes
  are public. The Mac app shows the repository name and excludes machine names,
  hostnames, URLs, and workspace labels from the environment block. Smart-input text
  and recordings are sent only to the selected companion's configured drafting and
  transcription services; neither is published. Only the reviewed, edited title and
  description reach GitHub.
- **Outbound text gate.** Every text the daemon posts to GitHub (issue comments, the
  pull request title and body, review comments, the merge commit body) is scrubbed of
  local paths, tailnet names and addresses, private keys and GitHub tokens before it
  leaves the machine. The pickup comment never carries the dashboard URL: the dashboard
  binds to a tailnet address and its API may be token-less, so the URL stays in the
  ledger and on the dashboard itself.
- **Merge and release gates.** Squash merges are pinned to the commit that was verified
  and reviewed (`--match-head-commit`) and carry an explicit body. Immediately before
  merge, the daemon revalidates that the exact head has a posted approval satisfying every
  current requirement. Legacy stored approvals without the structured assessment return
  to review; pending review reposts are revalidated too. A branch that moved after review
  goes back to CI, and squashed commit messages can never auto-close an issue early. The
  release author's commit must change exactly
  `release/macos.json` and the notes file and carry the exact commit subject before it
  is pushed, and the privacy check refuses to run when a branch modified
  `scripts/check-public-source.py` itself.
- **Release retries back off.** After a failed batch the poller waits ten minutes,
  doubling up to six hours, before trying again; **Release now** (or `release-now`)
  retries immediately. A resumed batch rebuilds the recorded source commit for exactly
  the issues its notes cover (issues merged later wait for the next batch) and reuses
  an already-prepared build instead of signing and notarizing again.
- **Disk space.** Worktrees are removed right after merge and after skips; `cleanup`
  and the dashboard action remove leftovers from blocked or failed issues.
- **Clean shutdown.** On SIGINT/SIGTERM the daemon stops polling and waits for running
  stages to finish their current step (up to the session timeout plus a minute) before
  it closes the ledger, so a merge or task that just completed is recorded. A dashboard
  that cannot bind (port in use, address not assigned) is reported as a plain error and
  nothing is started.

### Existing in-flight runs

Runs planned or reviewed before the requirement-assessment contract may need a fresh
planning or review session. The daemon does not grandfather legacy approvals. These
structural checks enforce traceability and merge invariants, but they cannot mathematically
guarantee that a model reasoned correctly; concrete evidence and human inspection remain
important for high-risk changes.

Screenshot labels, IDs, display names, and ordering are observations, not canonical
identities or whitelist entries. Machine- or operator-specific presentation stays in the
private configuration, while public source and examples use generic defaults.

## Housekeeping

`herdr-prune-runtimes` prunes installed companion runtimes under
`~/Library/Application Support/Herdr/Backend/` that are no longer referenced by a
LaunchAgent, Pi package settings, a `herdr-*` wrapper, or the harness launcher, while
keeping the newest few.

```sh
herdr-prune-runtimes
herdr-prune-runtimes --apply
```

The first command is a dry run that prints a JSON report; the second deletes the
reported unused runtimes.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| The Mac app says to update the companion server | The running server does not advertise `issue-reports-v1`; install the newer package. |
| AI drafting is unavailable but manual reporting works | The companion does not advertise `issue-report-draft-v1`, or its Pi has no usable default. Update the companion separately or write the report by hand; no generic-agent fallback is used. |
| Report fails with `github_failed` | `gh auth status` on the server machine; repository configured under `[code_factory]`. |
| Issue never leaves **Picked up** | Daemon not running, wrong `allowed_authors`, or missing trigger label. Run `doctor`. |
| DeepSeek sessions fail immediately | `OLLAMA_API_KEY` is not available to the daemon; add it to `[environment]`. |
| Planner blocked with a question | Answer on the issue, adjust the description if needed, then **Retry**. |
| Planner blocks but no alert arrives | Confirm the Message Me skill exists at `~/.codex/skills/message-me/scripts/message_me.py`, then inspect the issue event log for the recorded delivery status. |
| Release stays **failed** | Read the error in the release card; a red Verify run or a Keychain prompt are the usual causes. Fix, then **Release now**. |

## Verification

Python:

```sh
python3 -m unittest tests.test_issue_reports tests.test_issue_reports_http tests.test_issue_report_drafts \
  tests.test_code_factory_settings tests.test_code_factory_store tests.test_code_factory_github \
  tests.test_code_factory_git tests.test_code_factory_pi tests.test_code_factory_prompts \
  tests.test_code_factory_pipeline tests.test_code_factory_dashboard tests.test_code_factory_cli
```

Mac (from the repository root):

```sh
xcodebuild -project herdr-harness-mac/herdr-harness-mac.xcodeproj -scheme herdr-harness-mac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test \
  -only-testing:herdr-harness-macTests/IssueReportComposerTests \
  -only-testing:herdr-harness-macTests/IssueReportModelsTests \
  -only-testing:herdr-harness-macTests/IssueReportClientTests \
  -only-testing:herdr-harness-macTests/IssueReportDraftTests \
  -only-testing:herdr-harness-macTests/IssueReportDraftServiceTests \
  -only-testing:herdr-harness-macTests/IssueReportSmartInputTests \
  -only-testing:herdr-harness-macTests/IssueReportWiringTests \
  -only-testing:herdr-harness-macUITests/IssueReportSmartInputUITests
```

Live check: file a report from the app with one screenshot, confirm the issue renders the
image and the environment table, watch the dashboard move the issue through the stages,
and confirm the released version appears in **Herdr Companion → Check for Updates…**. For the
optional smart input, run the synthetic manual checklist in
[docs/issue-report-smart-input.md](issue-report-smart-input.md): real microphone glow, automatic
configured-service transcription, generated writing quality, the older-server manual fallback,
and no publication before **File report**. Do not treat a passing fixture-backed UI run as a
substitute for those checks.

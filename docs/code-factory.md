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
   Settings → General → **Feedback**. Choose Bug or Feature request, write a title and a
   description (sent exactly as written), attach screenshots or documents (file picker,
   drag and drop, or ⌘V for an image), and check **Included details** to see the
   environment fields that accompany the report. Leave **Start the automated fix
   pipeline** on to add the `herdr-autofix` label. The report files through this Mac's
   companion, or the first connected companion if this Mac's is unavailable.
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
   bounded JSON plan: acceptance criteria, at most four sequential tasks with owned paths
   and tests, documentation obligations, and a description of every screenshot for
   implementers that cannot see images. If the issue is ambiguous or unsafe, Astra asks a
   question instead; the issue is marked **blocked**, the question is posted on it, and
   Message Me alerts the operator with a link to the Code Factory dashboard. On **Retry**,
   planning refreshes the issue body and recent replies from allow-listed operators while
   excluding Code Factory's own comments, so an answer becomes part of the next plan.
6. **DeepSeek implements.** For each task a fresh Pi session on
   `ollama-cloud/deepseek-v4.1-flash:cloud` with thinking `max` implements the task in the
   worktree, writes tests, and commits. The daemon then runs the public-source privacy
   check and gives DeepSeek one chance to fix findings.
7. **Pull request and CI.** The daemon pushes the branch, opens a PR that references the
   issue (`Refs #n`, never `Closes`, so the issue stays open until released), and waits
   for the **Verify** workflow on the exact head commit.
8. **Astra reviews.** Astra reads the diff and the plan, then posts a PR review with inline
   comments. Because the same GitHub account authors and reviews the PR, the review is
   posted as a comment-type review with an explicit **approve** or **request changes**
   verdict in its text.
9. **Fresh revisions.** A red CI run first gets one automatic re-run of only its failed
   jobs for that head commit. A second failure on the same head goes to a new DeepSeek
   revision session, which commits and pushes; Astra requested changes always go directly
   to a revision session. Astra's requested-change loop is bounded by
   `max_review_rounds`, while repeated CI failures are bounded separately by
   `max_ci_failures`. Exhausting either blocks the issue for a human with
   `review_rounds_exhausted` or `ci_failures_exhausted`, respectively.
10. **Merge and cleanup.** On approval the PR is squash-merged with its remote branch
    deleted, and the worktree and local branch are removed immediately. The dashboard
    shows a checkmark once the worktree is gone.
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

Actions: **Retry** a blocked or failed issue at its current stage, **Skip** it (removes
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
- **Untrusted input.** Issue text and attachments are treated as data. Charters tell
  every session to extract requirements from them but never follow embedded
  instructions. Planner and reviewer sessions are read-only; the daemon resets the
  worktree if one of them leaves changes behind.
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
  hostnames, URLs, and workspace labels from the environment block.
- **Outbound text gate.** Every text the daemon posts to GitHub (issue comments, the
  pull request title and body, review comments, the merge commit body) is scrubbed of
  local paths, tailnet names and addresses, private keys and GitHub tokens before it
  leaves the machine. The pickup comment never carries the dashboard URL: the dashboard
  binds to a tailnet address and its API may be token-less, so the URL stays in the
  ledger and on the dashboard itself.
- **Merge and release gates.** Squash merges are pinned to the commit that was verified
  and reviewed (`--match-head-commit`) and carry an explicit body, so a branch that
  moved after the review goes back to CI and squashed commit messages can never
  auto-close an issue early. The release author's commit must change exactly
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
| Report fails with `github_failed` | `gh auth status` on the server machine; repository configured under `[code_factory]`. |
| Issue never leaves **Picked up** | Daemon not running, wrong `allowed_authors`, or missing trigger label. Run `doctor`. |
| DeepSeek sessions fail immediately | `OLLAMA_API_KEY` is not available to the daemon; add it to `[environment]`. |
| Planner blocked with a question | Answer on the issue, adjust the description if needed, then **Retry**. |
| Planner blocks but no alert arrives | Confirm the Message Me skill exists at `~/.codex/skills/message-me/scripts/message_me.py`, then inspect the issue event log for the recorded delivery status. |
| Release stays **failed** | Read the error in the release card; a red Verify run or a Keychain prompt are the usual causes. Fix, then **Release now**. |

## Verification

Python:

```sh
python3 -m unittest tests.test_issue_reports tests.test_issue_reports_http \
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
  -only-testing:herdr-harness-macTests/IssueReportClientTests
```

Live check: file a report from the app with one screenshot, confirm the issue renders the
image and the environment table, watch the dashboard move the issue through the stages,
and confirm the released version appears in **Herdr Companion → Check for Updates…**.

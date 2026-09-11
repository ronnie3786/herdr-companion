# Herdr Companion

Native Mac and iPhone apps, a web client, and one standalone companion server
for [Herdr](https://herdr.dev). Follow terminal sessions, chat with Pi agents,
manage notes and Active Work, review changes, and receive agent results.

The companion server owns its API, authentication, event streams, local tools,
attachments, and state. Install the upstream Herdr terminal separately. Git,
Pi, and optional integrations are ordinary external tools; no other dashboard
or orchestration repository is required.

## What Herdr can do today

Herdr is an experimental personal tool under active development. Expect rough
edges and changing workflows. This is a running feature list, not a promise that
every client supports every feature or that all integrations work without setup.

| Feature | What it does |
| --- | --- |
| Multiple computers | Save your computers in one private configuration and switch between their workspaces and sessions. Connection credentials stay in Keychain in the native apps. |
| Mac, iPhone, and browser clients | Follow work from a native desktop app, your phone, or a browser connected to your companion server. The clients have different capabilities. |
| Terminal sessions | Browse workspaces and panes, see terminal output, and send input to a running upstream Herdr terminal session. |
| Comfortable reading on Mac | A charcoal and lavender interface with 15-point system-font conversation text at the default scale in Chat and the HUD, bounded reading width, and Quiet chrome navigation. The prompt keeps labeled Attach, Paste code, and Voice actions close at hand, with Terminal keys above the input. Paste code appends a fenced clipboard block at the end of the draft; Command-Shift-V does the same while a Chat or HUD prompt is focused. Both routes preserve native undo and target their own composer even after a focus change. Long drafts scroll with the mouse or trackpad after five visible lines. Shift-, Option-, and Command-Return are handled before SwiftUI key dispatch in both chat and HUD editors, inserting a newline at the caret without sending and preserving undo/redo. Terminal follow re-anchors after viewport resizing and mode switches. Command cards show a three-line preview, the full command on expansion, and available structured input and partial output while running. Tool groups are labeled Clanking and stay collapsed on failures, with a failure count in the header. Appearance follows the app text-size preference. No server update is needed. |
| Pi agent conversations | Chat with Pi agents, follow their replies and tool activity, attach files in a compact, horizontally scrolling strip, and choose available models and reasoning settings. On Mac, the chat header shows the machine. Use the star beside its title to add or remove the chat from Starred. Click its title to edit inline (Enter or focus loss saves, Escape cancels). Right-click a sidebar chat or chat header and choose Smart Rename for a contextual title using a separate quick AI run with low thinking and your Quick Chat model setting. Requires the existing headless agent API and a readable Pi conversation. You can also use the pane actions menu, or right-click a sidebar chat, HUD session, or chat header to copy its workspace pane ID. The pane actions menu groups view, control, Pi session, and pane actions. Compact Chat and Reload Pi extensions (`/reload`) live in the prompt's … More popover. Requires Pi and its configured providers. |
| Pi session families | The Mac sidebar nests spawned Pi sessions beneath their parents, with collapsible children and workspace labels for work in another workspace on the same machine. Install the matching companion and Pi package; see the [Pi upgrade instructions](pi-semantic-bridge/README.md#upgrade-running-pi-sessions) for existing sessions. |
| Contextual questions | Ask about selected Git code, the current Herdr pane from the Mac HUD, or a note. Inspect and add context, resume questions, and explicitly continue in an agent for actions. Requires a companion with `contextual-question-v1`; the initial question profile uses supplied context with all tools disabled. |
| Saved HUD chats | The Mac HUD’s clock button opens searchable **Chat history** on the selected machine. **New chat** saves rather than deletes the conversation. Chats and their Pi sessions remain indefinitely in private server storage, outside terminal workspaces; **Continue in agent** explicitly promotes the full conversation. Agents can find them with `herdr-hud-chats list`, `search <text>`, and `show <agr_ID>`. HUD chats use normal Pi tools, skills, extensions, and project context, subject to existing Pi project trust settings—not a read-only or Herdr-sandboxed profile. Requires the updated companion server, CLI, and Pi package; older servers show an upgrade message before new HUD submissions. Contextual note/code questions keep their separate restricted profile. See [HUD history](docs/hud-chat-history.md). |
| Floating Mac assistant | Use a compact floating panel to send prompts and follow agent progress and results without keeping the main window in front. Choose the model and thinking level directly above the HUD prompt; thinking changes persist to HUD Settings and apply to the next prompt, including thread replies. The chat header omits New note and Ask actions; notes remain available in the note stack and File menu. The chat card uses soft, low-opacity shadows. Settings → HUD → Visible agents defaults to 4, with additional agents grouped under a compact circular +N. Choose 1–20 or Show all for an uncapped, scrollable list; clicking +N temporarily reveals every agent. No server update is needed. Session notification bubbles use natural one- or two-line title heights, with measured panel and scroll budgets. The model name and cumulative Pi cost alternate together across all bubbles with a gentle fade every five seconds beside the status; metadata refreshes every 15 seconds. New and revealed bubbles join the shared phase immediately. A missing value is not substituted with invented metadata. Audio controls sit at the top right. Updated companions allow headless runs for one hour by default; existing timeout overrides remain effective. Set `HERDR_HARNESS_AGENT_TIMEOUT_SECONDS` in the private configuration's `[environment]` table for a limit from 1 to 86,400 seconds. |
| Chat quotes and session chapters on Mac | Native selection keeps text wrapping and row heights aligned during window resizing and streaming. Select text or code in any of the last three completed, text-bearing agent messages, choose **Quote & comment…**, and Save a previewable quote chip. Interleaved tools and empty messages do not consume quote slots. User messages, replies outside that window, and historical chapters remain copyable but do not offer quoting. Quotes and their comments are sent inline under **Quoted response segments:**, not as file paths. Save never sends. New Pi chat shows progress, confirms the changed session, and keeps the previous transcript above a visible divider with its copyable closed-session ID—even while the new session is empty. Local history survives relaunch without feeding old context to the new agent. See [interaction details and limits](docs/mac-chat-quotes.md). No server update is needed. |
| Notes | Notes use ink-colored cursors and title placeholders, with title/body defaults another point larger. The note-card header no longer includes New note; creation remains in the note stack and File menu. Use the labeled **Actions** menu for **Ask about this note**, **Tidy with AI**, and **Take action**; busy-state guards remain in place. Create notes from the Mac HUD note stack or File → New Note (Shift-Command-N), including when no notes exist. On the collapsed Mac HUD, hover over the HUD to reveal Notes at the orb's bottom-left corner, mirrored against Mic at bottom-right, and X at top-right. All three controls are 20% smaller and hidden at rest. Click Notes to expand or minimize the list; the expanded chat retains its Notes toggle below the card. Capture ideas in resizable note cards, edit their title and text on iPhone, and use them as context for agents. iPhone saves sync through the companion and detect conflicting edits. |
| Active Work board | Start from a template, then edit each ticket's path with review loops and extra steps. See the current action, owner, checkpoints, visit history, and agent handoff. Return to linked sessions. See [ticket paths](docs/ticket-paths.md) for board and agent controls. |
| Recent chats on Mac | Choose Recents from the sidebar clock menu for roomier rows (10 extra points between chats), single-line titles with quiet machine/workspace context and explicit Working, Done, or attention status. The secondary line is 1 point larger, with the project/workspace name in bold. Hover for full tab context or right-click to open the workspace. Sidebar titles and statuses observe live panes, including Smart Rename and completion updates. Selected chats use a background highlight without a leading stripe. Other sidebar categories keep compact labels without the Recents subtitle when switching filters. Requires no server update. |
| Tab colors on Mac | Right-click a tab, sidebar chat (including Recents), workspace chat card, or chat header → **Tab color** to assign or remove one of six muted accents: Lavender, Iris, Rose, Clay, Sage, and Slate. Every chat in the tab inherits the color, including future panes; sidebar rows and Pi chat backgrounds match. Active colors appear between **Filter chats** and **New session**. Click a color label to filter all sidebar categories to that color, intersecting the search, machine, and recency filters; click it again or **Show all colors** to clear. Use the pencil for inline label editing (Enter or click away saves; Escape cancels), or right-click → **Smart Rename** to prefer a Jira key/title present in the grouped conversations. Smart Rename uses the existing Quick Chat model and readable Pi conversations; it uses supplied context rather than querying Jira. Labels are shared by tabs using the same color. Assignments and labels persist locally on this Mac, not across clients; no server update is needed. |
| Activity and attention | See recent activity and identify sessions that need attention. On Mac, right-click a sidebar chat and choose **Mark Unread** for a persistent local green-check reminder. Opening or interacting with the chat clears it; **Mark Read** clears it manually. This does not change the agent’s real status, send alerts, or restore a HUD notification bubble. No server update is needed. |
| Sidebar creation | Use the labeled New workspace action, or hover a machine row and click its folder-plus button to create directly on that machine. Right-click a workspace heading—including Unread and Starred groups—for New tab. Creation requires a controllable machine. |
| Navigation history | Back and Forward include switches between Chat and Git on the same pane, as well as other segment destinations. |
| Git changes | Inspect repository changes and diffs from a workspace. Mac diffs retain the lavender chrome with prominent red/green line, gutter, and changed-text backgrounds. File rows prioritize the complete filename with a left-truncated directory hint and full-path hover tooltip. These Mac presentation changes need no server update; browser file rows require updated web assets. Requires Git and the built web assets for the Mac Git view. |
| Files and skills | Search workspace files, attach context, and browse available agent skills. |
| Agent results | View returned files and other result attachments alongside agent responses. Mac Chat hides orphaned attachments whose original response is absent, instead of showing an “Other session attachments” section; associated cards and stored artifacts are unchanged. |
| Voice input and spoken replies | Dictate prompts or notes and listen to responses when compatible transcription and speech services are configured. |
| GitHub and Jira context | Bring review requests and tickets into your workflow using your own authenticated GitHub and Jira command-line tools. |
| Fleet management | Manage configured skill catalogs and destinations across your computers. Requires a trusted catalog and local configuration. |
| Workspace cleanup | Preview suggested cleanup decisions and inspect what will be affected before applying them. |
| Notifications and app links | Receive configured push notifications and open supported destinations in the iPhone app. Requires your own Apple push and domain setup. |
| Mac app updates | Check a signed GitHub Releases feed, see an update banner, and choose to install and relaunch. Includes an optional preview channel. Existing custom installations need a one-time setup; see the update guide below. |
| Independent components | Update the Mac app, iPhone app, or companion server separately when their API versions are compatible. Mac self-updates leave the server running. |
| Private local setup | Keep machine addresses, provider settings, and credentials outside Git while continuing to pull the shared source. A downloadable sample shows what to fill in. |
| Demo mode | Explore the native apps with synthetic data using `-HerdrDemoMode`, without connecting a real cluster. |

When adding or changing a user-facing feature, update this list and describe any
setup it needs. Release notes record what changed in a particular version.

See the [roadmap](ROADMAP.md) for deferred work and open product decisions,
including whether to improve or retire the standalone web companion.

## Start the server

Clone this repository, then run the commands below from your checkout.

Requirements: Python 3.11+, Node.js 22.19+, Git, and a running upstream Herdr
session. Install Pi to use agent chats. Native builds target macOS/iOS 26+
and have been verified with Xcode 26.2.

```sh
cd herdr-companion
python3.11 -m venv .venv
.venv/bin/python -m pip install -e '.[dev]'
npm --prefix frontend/herdr-web ci
npm --prefix frontend/herdr-web run build
.venv/bin/herdr-config init
.venv/bin/herdr-config check --machine desktop
.venv/bin/herdr-server --machine desktop
```

`herdr-config init` creates `~/.config/herdr-companion/config.toml` with owner-only file
permissions and a random API token. It never overwrites an existing file and
does not print the token. Open that file in your editor to customize it.

The default server listens on `127.0.0.1:9092`. Open
`http://127.0.0.1:9092/herdr-web/`, or connect a native app to that origin and
enter the API token from your private configuration. A token is required by
default. `--allow-insecure-local` is an explicit loopback-only development option.

Core Python code has no third-party runtime dependencies. The web build is
required for the browser client and Mac Git view. Build the web client before
making a Python release package; the wheel includes these assets and Pi extensions.

## One private configuration for your computers

[config.example.toml](config.example.toml) is the complete downloadable sample.
It contains fictional machines and commented provider examples. You can copy it
instead of using the initializer:

```sh
mkdir -p ~/.config/herdr-companion
cp config.example.toml ~/.config/herdr-companion/config.toml
chmod 600 ~/.config/herdr-companion/config.toml
```

Set a strong random `server.api_token` before starting the server. Keep the
filled-in file outside the repository. A checkout-local `config.local.toml`
is also supported and ignored by Git. The sample is the only configuration
file intended for publication.

The same private file can describe your complete cluster:

```toml
version = 1

[server]
host = "127.0.0.1"
port = 9092
state_dir = "~/.local/share/herdr-companion"

[machines.desktop]
name = "Desktop"
role = "local"
url = "https://desktop.example.invalid"

[machines.desktop.server]
api_token = { env = "DESKTOP_HERDR_TOKEN" }

[machines.laptop]
name = "Laptop"
role = "work"
url = "https://laptop.example.invalid"

[machines.laptop.server]
api_token = { env = "LAPTOP_HERDR_TOKEN" }

[providers.transcription]
backend = "openai"
url = "https://speech.example.invalid/v1/audio/transcriptions"
model = "your-model"
token = { env = "SPEECH_API_KEY" }
```

Select the local machine explicitly on each computer:

```sh
herdr-server --config ~/.config/herdr-companion/config.toml --machine desktop
herdr-server --config ~/.config/herdr-companion/config.toml --machine laptop
```

Use different API tokens for individual machines. Secrets may live in the private
TOML, an environment variable (`{ env = "NAME" }`), or an existing owner-only
file (`{ file = "path" }`). Typed settings also accept an `_file` suffix, such as
`api_token_file`. Values are parsed as data, never shell code.

Configuration selection: `--config`, then `HERDR_CONFIG`, then
`./config.local.toml`, then `~/.config/herdr-companion/config.toml`. Machine selection:
`--machine`, then `HERDR_MACHINE`, then the file's top-level `machine` setting.
Explicit CLI arguments override process environment; environment overrides
per-machine settings; per-machine settings override shared settings. Each machine
can override shared tables. `[environment]` exposes additional Herdr settings
without a second configuration file.

The authenticated `/api/v1/config/machines` endpoint returns only machine
names, IDs, roles, and server origins. Native build configuration can seed this
same roster. API tokens are never included in the roster or compiled into apps.
Native connection credentials are stored in Keychain.

## Optional integrations

| Feature | Configuration / requirement |
| --- | --- |
| Git, file search, skills, uploads | Built into the server; Git must be installed for Git operations. |
| Pi chats and tools | Install Pi and configure its providers. Extensions are tested with Pi 0.84.2. |
| GitHub reviews | Authenticate `gh`; configure optional automation under `[integrations]`. |
| Jira | Authenticate `acli` and configure your Jira site. No tenant or project is assumed. |
| Transcription | `[providers.transcription]` supports OpenAI-compatible and Parakeet services. |
| Summaries and quick voice | `[providers.summary]`, `[providers.voice]`, and `[providers.activity]`. |
| Spoken responses | Set a Kokoro/OpenAI-compatible endpoint under `[providers.tts]`. |
| Fleet catalogs | Configure a trusted `[fleet]` repository and additional skill destinations. |
| Active Work automation | Generic board API/CLI; Buzz sync and review polling are optional. |
| APNs and universal links | Configure `[push]` and `[apple]` with your own identity/domain. |
| Remote access | Configure your HTTPS origin. Tailscale Serve is optional. |

Unconfigured providers report unavailable capabilities and do not contact a
built-in private endpoint. Server and CLI entry points share the TOML. The
Pi package's [README](pi-semantic-bridge/README.md) covers handoff, notes, and results.

For Pi started from your shell, apply the same machine configuration:

```sh
herdr-config exec --machine desktop -- pi
```

This passes the local API credentials and agent settings through the environment,
without printing credentials or including them in command arguments. Server-only
administration and remote-machine secrets are filtered out. Pi launched inside
Herdr discovers the running companion through an owner-only connection record
keyed to the terminal socket. This record is generated state, not another file
you need to configure.

For Tailscale, run `tailscale serve --bg --https=8461 9092`, then put your actual
HTTPS origin in the private roster. Set `HERDR_HARNESS_TAILSCALE_URL` under the
private `[environment]` table to advertise the configured route. Tailscale
access does not replace Herdr API authentication.

## Build the native apps

Open either `.xcodeproj` in Xcode, or build unsigned contributor versions:

```sh
xcodebuild -project herdr-harness-mac/herdr-harness-mac.xcodeproj \
  -scheme herdr-harness-mac -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project herdr-harness-ios/herdr-harness-ios.xcodeproj \
  -scheme herdr-harness-ios -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Both apps have demo mode (`-HerdrDemoMode`). For your signed builds, configure
`[apple]` in the same private TOML, then run:

```sh
.venv/bin/python herdr-harness-mac/Scripts/configure-apple.py \
  --config ~/.config/herdr-companion/config.toml --machine desktop
```

This generates ignored local Xcode settings, entitlements, and optional machine
bootstrap metadata. Keep these files and resulting private artifacts out of
public releases. Public releases must use neutral settings and synthetic demos.
Configure signing team, bundle IDs, Keychain identity, associated domains, and APNs
topic together. Existing installations may need private identity overrides or
re-pairing when these values change.

Direct Mac installations use the secure login Keychain by default and require no
App Store submission. See [Apple configuration](herdr-harness-mac/APPLE_CONFIGURATION.md)
for the optional Data Protection backend and the credential deployment probe.

## Mac app updates

Configured release builds check their signed GitHub Releases feed every four hours.
An available update appears in a banner: choose **Review update…**, then use
Sparkle's confirmation to install and relaunch. You can also choose **Herdr Companion →
Check for Updates…**. Settings controls automatic checks and optional preview
builds. This updates the Mac app independently of the companion server and uses
no App Store submission.

Personal testing releases can use Apple Development signing without Developer ID
or notarization. Signed update verification stays enabled. These builds are
experimental and may need normal macOS approval on first installation.

See [macOS releases](docs/macos-releases.md) for signing modes, the
prepare/publish commands, and the first transition from a private app identity.
The release metadata and tooling do not imply that a public binary has been
published or that a signing certificate is configured.

## Update components independently

The Mac app and companion server can run different tested source revisions. Record
an installed revision and artifact hash for each component. Check the release's API
and state-format requirements before updating one side; independence does not make
arbitrary versions compatible.

For a **Mac-only update** of a configured release, use the app's update
controls described above. For a custom private build, generate Apple settings from
your existing private TOML, build and test the selected Mac revision, and install
its signed app bundle. Retain
the bundle and Keychain identities, back up the installed app and settings, and run
the [signed credential probe](herdr-harness-mac/APPLE_CONFIGURATION.md#verify-signed-credential-access-before-deployment)
on the destination. Keep the server runtime and its services running at their
current revision. Verify that the new app connects to that server before retiring
the previous app bundle.

For a **server-only update**, build the web assets and wheel from the selected
tested revision, install a new versioned runtime, and follow the
[server update procedure](herdr_harness/README.md#update-the-server).
Keep the installed native apps. Update the matching installed CLIs, Pi extension,
and any enabled background workers as part of the server change. Configuration-only
changes need validation and a restart of affected processes, not a new wheel.

Preserve the private TOML, credential files, and configured state locations during
both kinds of update. Keep the previous artifacts and service definitions for
rollback. Restore only the affected component unless compatibility requires a
matched pair; do not restore an older database over new user data without a
separate, consistent backup and a state migration plan.

## Development and verification

```sh
.venv/bin/python -m unittest discover -s tests
npm --prefix pi-semantic-bridge ci
npm --prefix pi-semantic-bridge test
npm --prefix frontend/herdr-web test
npm --prefix frontend/herdr-web run build
.venv/bin/python scripts/check-public-source.py
.venv/bin/python -m build
```

Enable the repository's private-source guard in your checkout:

```sh
git config core.hooksPath .githooks
```

CI also checks source, scans Git history for credentials, runs the Python/web/Pi
suites and native unit targets, and tests a wheel from an empty working directory.
To repeat the independent-install check locally:

```sh
python3.11 -m venv /tmp/herdr-wheel
/tmp/herdr-wheel/bin/python -m pip install dist/*.whl
.venv/bin/python scripts/verify-installed.py --python /tmp/herdr-wheel/bin/python
```

Run native unit and demo UI suites from Xcode on a suitable Mac/simulator.
Interactive tests need the OS permissions required by their test host. Test
servers use temporary loopback ports and state.

Before upgrading, take consistent backups. SQLite uses WAL: use its backup API
or stop writers and checkpoint, instead of copying a database while it is being
written. Preserve credentials, notes, jobs, artifacts, and board state privately.

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Source is MIT licensed; included
third-party materials retain their licenses.

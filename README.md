# Herdr companion

Native Mac and iPhone apps, a web client, and one standalone companion server
for [Herdr](https://herdr.dev). Follow terminal sessions, chat with Pi agents,
manage notes and Active Work, review changes, and receive agent results.

The companion server owns its API, authentication, event streams, local tools,
attachments, and state. Install the upstream Herdr terminal separately. Git,
Pi, and optional integrations are ordinary external tools; no other dashboard
or orchestration repository is required.

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

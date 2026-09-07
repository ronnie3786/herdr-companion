# macOS app updates and releases

Herdr distributes direct Mac app updates through a signed GitHub Releases feed,
using Sparkle 2.9.6. App Store submission is not part of this workflow. The Mac app
and companion server are separate components: an app update replaces the app
bundle and relaunches it. It does not deploy a server wheel, restart server
services, or update the iOS app. Check each release's compatibility requirements
before updating either component.

This document describes the release tooling. It does not assert that a public
binary is already available or that publisher signing credentials are configured.

## Install an available update

In a configured release build, automatic checks use a four-hour interval while
the app is running. A scheduled check that finds an update shows a banner. Choose
**Review update…** to open Sparkle's release information, then choose whether to
install. Sparkle verifies the download and handles installation and relaunch.
**Later** hides the banner; **Herdr → Check for Updates…** can reopen the pending
update. Checking automatically does not consent to automatic installation.

In **Settings → App updates**, you can turn automatic checks on or off, check
manually, and opt into **Include preview builds**. Stable releases are included
when previews are enabled. Finish or skip a pending update before changing
release channels. Builds without a matching feed configuration or application identity leave
updates unavailable.

The feed's signature and each archive's signature must match the public key
pinned into the app. Verification happens before archive extraction. The feed
also separates stable releases from the `preview` channel. A result saying no
compatible update is available does not imply every preview or incompatible
release is installed.

## Configure the publisher once

Use the existing private `~/.config/herdr-companion/config.toml`. There is no
separate release environment file. Add the commented
`[deployment.macos_release]` example from [config.example.toml](../config.example.toml)
and replace its fictional values. Per-machine overrides are supported through
`[machines.desktop.deployment.macos_release]`; select that machine with
`--machine desktop`.

Required tools and credentials:

- Xcode and Python 3.11 or newer, plus `gh` authenticated with permission to publish
  releases to the configured repository.
- A **Developer ID Application** certificate and its private key in Keychain.
  Apple Development and ad-hoc signatures are not accepted by the public publisher.
- A notarytool Keychain profile, referenced by `notary_profile`. An optional
  `notary_keychain` selects another Keychain file. For interactive setup, use
  `xcrun notarytool store-credentials herdr-notary` and follow its prompts.
- The official Sparkle 2.9.6 tools directory, containing `generate_appcast`,
  `generate_keys`, and `sign_update`. The script checks their pinned hashes.
- A `sparkle_key_account` that already holds the Ed25519 private key matching the
  committed public verification key. Changing an account name does not rotate or
  replace the app's trusted key.

Keys and notarization credentials stay in Keychain. The TOML holds identity names,
profile names, account names, and local paths, never exported private keys. On the
first preparation, macOS may ask permission for `generate_appcast` to access its
signing key. Complete that Keychain prompt deliberately on the publishing Mac.
A timed-out prompt leaves a failed preparation, not a publishable manifest.

Developer ID code signatures publicly identify their certificate's publisher
name and team ID. Privacy scanning cannot make those certificate fields anonymous.
Keep explicitly authorized public certificate identity and team metadata out of
your list of forbidden private patterns.
For a downstream fork, deliberately establish its repository, bundle identity,
feed, and signing key together; the official publisher intentionally pins those
public distribution values.

An optional `private_patterns_file` references an owner-only JSON array of
additional case-insensitive regular expressions for the privacy scan. For example,
a private file could contain these fictional patterns:

```json
["private-cluster\\.example\\.invalid", "/Users/example/"]
```

Keep real patterns outside Git and restrict the file to its owner with `chmod 600`.
The publisher reads this input through the same private TOML reference and refuses
unsafe secret-file permissions. Matching private values are not echoed in errors.

## Choose the version

Run commands from the repository root, using its development virtual environment.
[release/macos.json](../release/macos.json) is the committed version source:

```sh
.venv/bin/python scripts/release-macos.py plan
```

The initial metadata describes **0.2.0-beta.1**, build **2**, on the preview
channel, with tag `macos-v0.2.0-beta.1`. `plan` reads public metadata only and
performs no Keychain access or network requests. Preparing this initial version
does not need another bump.

For a subsequent feature preview:

```sh
.venv/bin/python scripts/release-macos.py bump --channel preview
.venv/bin/python scripts/release-macos.py plan
```

The default bump is **minor**, so that example advances 0.2.0 to 0.3.0 and starts
its first preview. Every bump also increments the build number. Other choices:

| Intention | Command arguments after `bump` |
| --- | --- |
| Next feature preview | `--channel preview` |
| Patch preview | `--part patch --channel preview` |
| Another preview of the same version | `--part build --channel preview` |
| Promote the current preview to stable | `--part build --channel stable` |
| Next stable minor release | no arguments |

The default channel is stable, so include `--channel preview` when intended.
Reusing an existing stable version is rejected. The build number must exceed
both stable and preview builds already in the feed.

## Commit and verify the exact source

Commit the version metadata and all reviewed application, tooling, and documentation
changes. Push the commit, then wait for the latest **Verify** workflow run for that
exact commit to succeed. Keep the working tree clean, including untracked files.
For example, after a version-only bump:

```sh
git add release/macos.json
git commit -m "Prepare next macOS preview"
git push
gh run list --workflow Verify --commit "$(git rev-parse HEAD)" \
  --limit 1 --json headSha,status,conclusion
```

A successful run on a previous commit is insufficient. Both preparation and
publication enforce this check. A failing test or privacy check must be repaired
before publishing.

## Prepare and review the artifacts

Review the initial preview's [release notes](../release/notes/macos-0.2.0-beta.1.md).
For later releases, write concise UTF-8 Markdown notes covering visible changes,
server compatibility requirements, and how to find or test the changes. Commit
reviewed public notes under `release/notes`, or keep the input outside the checkout
so preparation still starts from a clean revision. Notes are privacy-scanned and
embedded in the update feed. The limit is 128 KiB. For the initial preview:

```sh
.venv/bin/python scripts/release-macos.py prepare \
  --config "$HOME/.config/herdr-companion/config.toml" --machine desktop \
  --notes release/notes/macos-0.2.0-beta.1.md \
  --output "$HOME/.local/share/herdr-companion/releases/0.2.0-beta.1"
```

Choose a fresh output directory that does not yet exist, and adjust the notes
and output paths for later versions. `--sparkle-tools /absolute/path`
can override the TOML tools directory for one invocation.

`prepare` exports the committed source with `git archive`, builds a neutral public
app, validates its identity and signatures, and scans the artifact before sending
it to Apple's notarization service. It then notarizes and staples the app,
creates and signs the archive/feed metadata, and preserves previous stable and
preview entries in the feed. Generated private Xcode settings, machine bootstrap
files, server addresses, and credentials are excluded from the public source
export. A private app build is not accepted as a public release artifact.

Successful output includes the app ZIP, release notes, signed `appcast.xml`,
`release.json`, its Ed25519 signature, `SHA256SUMS`, and `prepared.json`. Review the
notes and artifact metadata before publication. No GitHub release is published
by `prepare`. A failed preparation retains local diagnostic evidence but removes
`prepared.json`; use a new output directory after correcting the failure.

## Publish the reviewed preparation

Publish the exact manifest produced above:

```sh
.venv/bin/python scripts/release-macos.py publish \
  "$HOME/.local/share/herdr-companion/releases/0.2.0-beta.1/prepared.json" \
  --config "$HOME/.config/herdr-companion/config.toml" --machine desktop
```

The publisher revalidates signatures, asset hashes, and the successful CI commit.
It creates or verifies the version tag at that commit, uploads and verifies the
versioned release, then updates discovery through the signed rolling feed last.
Preview releases are marked prerelease. Stable releases become the latest app
release. Existing version tags and mismatched assets are never silently replaced.

The dedicated `macos-updates` release hosts the rolling appcast. It must remain
mutable, published, and marked prerelease; it is not an app download. Repository
release-immutability settings that prevent updating this feed must be resolved
before publication. A remote lock serializes publishers; do not start concurrent
publication attempts.

If publication is interrupted, retry the same reviewed `prepared.json`. The script
checks existing assets before resuming. If another release changed the feed since
preparation, prepare again in a new output directory. Do not manually edit signed
artifacts or overwrite versioned release assets to make a retry pass.

If the rolling feed became unavailable during GitHub's replacement upload,
ordinary retry stops. After confirming that no newer release was published, rerun
the same publish command with `--restore-missing-feed`. This explicit repair
requires the versioned release to be published already, with its tag and every
asset matching the prepared manifest. It never replaces versioned assets.

## First transition from a private app identity

An existing private build may use a different bundle identifier, preferences
domain, or Keychain service from the neutral public app. Its first transition is
an operator migration, not a routine Sparkle update. Preserve the previous app
and settings, the private TOML, and all server state. Follow the
[signed credential verification procedure](../herdr-harness-mac/APPLE_CONFIGURATION.md#verify-signed-credential-access-before-deployment)
for the destination identity, and re-pair machines or explicitly migrate their
credentials when needed. Verify machine connections and notes before retiring
the previous app. Never embed private credentials in the public artifact to
bridge this transition.

Once the public app identity is installed and paired, routine updates follow its
signed feed. They keep using the configured server. See
[independent component updates](../README.md#update-components-independently) for
server updates and rollback boundaries.

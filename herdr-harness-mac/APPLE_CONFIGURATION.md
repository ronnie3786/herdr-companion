# Apple app configuration

Both Xcode projects build with neutral `org.herdr.companion` development identifiers,
an empty signing team, no universal-link domains, and no configured terminal app.
These identifiers are examples for local development. Choose identifiers you control
before distributing signed builds.

The repository's private cluster TOML is the only hand-edited configuration source:

```toml
[apple]
team_id = ""
bundle_prefix = "org.example.herdr"
# Optional explicit IDs let existing private installations keep their identity.
mac_bundle_id = "org.example.herdr.macos"
ios_bundle_id = "org.example.herdr.ios"
widget_bundle_id = "org.example.herdr.ios.widgets"
keychain_service = ""
mac_keychain_backend = "login"
legacy_keychain_service = ""
associated_domains = []
apns_environment = "development"
terminal_bundle_id = ""

[machines.desktop]
label = "Desktop"
url = "https://desktop.example.test"
role = "local"
```

Activate the server virtual environment (Python 3.11 or newer), then generate local
build inputs from the repository root:

```bash
python3 herdr-harness-mac/Scripts/configure-apple.py --config /path/to/private/cluster.toml --machine desktop
```

The script creates `Local.xcconfig` and `Local.entitlements` beside each project, plus
an app `HerdrBootstrap.plist`. These files are ignored by Git. Xcode automatically
loads them through the checked-in `Defaults.xcconfig`. CLI build settings may still
be overridden through standard `xcodebuild` arguments. The generator reads metadata
without resolving server credential files, so a build machine needs no server secrets.

The generated roster contains only IDs, labels, URLs, and roles. It seeds the first
launch and leaves saved user settings intact. Enter each machine's token at runtime
in onboarding or Settings. No API token is compiled into the app. Machine roles are
explicit `local`, `work`, `development`, or `node`; names never select a private role.

`associated_domains` accepts values such as `applinks:herdr.example.test`. Leave it
empty unless you control a matching HTTPS origin and serve a matching Apple App Site
Association document. The `herdr://` URL scheme works independently. Set
`apns_environment` to match your signing profile, and configure the server's APNs
credentials and allowed app topics for your bundle IDs. The widget ID must extend
the iOS app ID with a dot and a suffix.

On macOS, `terminal_bundle_id` optionally enables foreground activation of an
installed terminal after a successful focus request. An empty value disables this
local convenience. It does not change server behavior or require another companion
server.

For private upgrades, retain the old app IDs and `keychain_service` in your private
configuration. If intentionally changing the service, set `legacy_keychain_service`
to the prior value for a migration build. Credentials are copied only when the new
Keychain save succeeds. The original service is retained for rollback. Old plaintext
fallback entries are removed after successful secure migration; new failed saves
never write credentials to UserDefaults. A changed signing identity or Keychain
access group may require re-entering tokens. Back up app settings before changing
application identity.

Build public releases from a clean checkout without these private generated files.
Local app artifacts include configured machine addresses, domains, and signing
identity even though they contain no API tokens.

## Mac credential storage for direct installation

The default `apple.mac_keychain_backend = "login"` uses the encrypted macOS
file-based login Keychain through the SecItem APIs. Items receive an access-control
list that trusts the creating application. A stable signing identity helps preserve
that trust across updates. Keychain may ask for authorization when an app's identity
changes or the login Keychain is locked. No App Store submission, Data Protection
access group, or provisioning profile is required for this default backend.

The login Keychain uses macOS file-based access controls. It does not provide the
Data Protection backend's `ThisDeviceOnly` accessibility class, biometric access
controls, or access-group authorization. Herdr does not claim those properties for
login-Keychain items. It never configures an allow-all-applications access list.

For a separately provisioned app, set `mac_keychain_backend = "data-protection"`.
The generator then adds `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)` as the
Mac Keychain access group. This option requires the appropriate signed entitlements
and Mac provisioning profile. Backend selection is explicit: a failed DP access
never silently switches a configured DP app to login storage. iOS continues to use
its existing Keychain implementation.

When the selected backend has no item, Herdr can securely copy an accessible item
from the previous backend or configured prior service. The source is retained for
rollback. Existing plaintext from older builds is removed only after its value is
successfully written to Keychain. Locked or denied reads and failed writes preserve
migration sources and leave the credential unavailable. New failed saves never create plaintext.
Deleting a credential removes accessible copies and records a nonsecret deletion
marker, so an inaccessible old backend cannot later restore a deleted credential.

Apple documents the two storage and access-control models in [TN3137: On Mac
keychain APIs and implementations](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).
The creating-app-only ACL follows [SecAccessCreate](https://developer.apple.com/documentation/security/secaccesscreate(_:_:_:)).

## Verify signed credential access before deployment

Run the final signed app executable with the same newly generated UUID for each
invocation. The probe exits before app models or windows initialize, accesses only
its synthetic Keychain item, and emits JSON containing numeric statuses and
verification booleans. It never reads saved settings, server tokens, or legacy
plaintext fallback entries. A failed verification exits nonzero.

```bash
probe_id=$(uuidgen)
app_binary="/path/to/Herdr.app/Contents/MacOS/herdr-harness-mac"
"$app_binary" --herdr-keychain-probe write "$probe_id"
"$app_binary" --herdr-keychain-probe read "$probe_id"
"$app_binary" --herdr-keychain-probe read "$probe_id"
"$app_binary" --herdr-keychain-probe delete "$probe_id"
```

Each command starts a separate process, so the reads verify persistence across
relaunches. Always run the delete step, including after a failed read. Deletion
also verifies that the synthetic item is absent. Test the installed copy on the
destination Mac: a unit-test host or a differently signed build does not prove
that the delivered app has usable Keychain entitlements.

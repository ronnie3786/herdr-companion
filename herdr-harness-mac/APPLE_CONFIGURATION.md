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

Test the exact final signed app through LaunchServices in the destination Mac's
logged-in GUI session. Directly invoking its executable from SSH can fail with a
CSSM security-session error even when the same binary works in the GUI session.
Use `open -a` with the exact app path, and require the probe's JSON result; a
successful `open` command alone does not establish Keychain access.

The probe exits before app models or windows initialize, accesses only a synthetic
Keychain item addressed by a new UUID, and reports numeric statuses and verification
booleans. It never reads saved settings, server tokens, or legacy plaintext entries.
Each invocation starts a separate process, verifying persistence across relaunches.

Run this Bash block on the destination, replacing the app path. Each operation gets
a fresh owner-only JSON file and private stderr log. The exit trap always attempts
deletion, including after a failed write or read, and requires confirmed absence:

```bash
(
  set -e
  umask 077
  probe_id=$(uuidgen)
  probe_dir=$(mktemp -d)
  app="/absolute/path/to/Herdr.app"

  run_probe() {
    local operation="$1" label="$2"
    local result_file="$probe_dir/$label.json"
    local error_file="$probe_dir/$label.log"
    : > "$result_file"
    : > "$error_file"
    /usr/bin/open -n -W -g --stdout "$result_file" --stderr "$error_file" \
      -a "$app" --args --herdr-keychain-probe "$operation" "$probe_id"
    python3 - "$result_file" <<'PYCODE'
import json, sys
with open(sys.argv[1]) as result:
    report = json.load(result)
if report.get("ok") is not True:
    raise SystemExit("Synthetic Keychain verification failed")
PYCODE
  }

  cleanup() {
    local probe_exit_code=$?
    trap - EXIT
    if ! run_probe delete cleanup; then probe_exit_code=1; fi
    printf 'Private probe reports: %s\n' "$probe_dir"
    exit "$probe_exit_code"
  }
  trap cleanup EXIT
  run_probe write write
  run_probe read read-1
  run_probe read read-2
)
```

Do not add `open -F`: it discards saved persistent application state. Repeat the
probe against the installed copy after replacement. A unit-test host or differently
signed build does not prove that the delivered app can access its Keychain.

# First Mate on iPhone and iPad

First Mate gives each feature its own conversation in the iOS app. Choose a host,
open a feature, and give its First Mate direction in plain English. The companion
server owns the workflow, agents, checkpoints, documents, and saved sessions.
Closing the phone app does not stop work on the host.

## Navigation

The **First Mate** tab opens your features, with items waiting for your direction
first. Search by title or goal, or create a feature with its goal and repository
folder on the selected host. Existing workspace folders are available as shortcuts.
The existing **Agents** tab remains available for ordinary Pi conversations.

Long-press a feature to archive it. The confirmation offers an optional reason,
states that all records are retained, and explicitly says when work continues.
Use **Show archived** in First Mate options to reveal an Archived section with an
Unarchive button on every card.

On iPhone, a feature opens its conversation. Use the feature controls to inspect
Overview, Workflow, Agents, or Documents, then return to the same conversation.
On iPad, the feature list stays in a sidebar and an inspector uses the available
space. First Mate supports System, Light, and Dark appearance from its options
menu. It uses scalable text and native scrolling and navigation.

Workflow offers a journal and a graphical route through recorded stages. Each
stage exposes its documents and agents through compact controls. Open an agent
to read its exact saved Pi session, including retained sessions from handoffs.
Earlier transcript pages can be loaded without switching to a newer conversation.
Documents retain their producing agent and session. The seven-reviewer demo shows
how a larger team remains accessible without filling every workflow card.

## Behavior and compatibility

Mac and iOS compile the same First Mate models, observable store, resource loader,
and synthetic demo from `HerdrFirstMateShared`. Their native layouts are separate.
Both use the authenticated `first-mate-v1` companion API. The matching server
release is required; an older server shows an update explanation. Updating the
phone app does not install or activate a companion server.

The app polls while First Mate is visible in the foreground and refreshes after
sending direction. Switching features preserves their unsent drafts in memory.
Returning from another tab or from the background preserves the current feature.
Changing hosts or connection credentials fences old requests and clears old host
content before loading the new host. Drafts are not persisted across app launches.

Every major workflow stage still waits for human direction. Sending a message
records a request and returns control to the conversation while the host proceeds
asynchronously. Pause, resume, and cancel act on that feature. Cancel requires
confirmation. Viewing a document or saved session does not send an agent a prompt.

## Local verification

Launch with `-HerdrFirstMateDemo` for synthetic features without a server. The
scenario control advances through planning, implementation, seven independent
reviews, a human checkpoint, revised direction, and a verified session handoff.
Ordinary `-HerdrDemoMode` continues to open the existing Agents experience.

Use the repository's iOS Xcode scheme and verification instructions. Shared
First Mate contract tests compile into both the iOS and Mac unit-test targets.
The iOS UI tests cover feature navigation, composing direction, workflow resource
drilldown, appearance, and larger text. Test screenshots use synthetic data only.

### Authenticated simulator fixture

From the repository root, start the local fixture:

```sh
python3.11 scripts/first-mate-ios-fixture.py --port 9196
```

It binds to loopback and uses the production HTTP handler, authentication,
First Mate SQLite store, and saved-session reader. Its runtime cannot launch
agents. Create and message requests receive a deterministic acknowledgment and
do not advance workflow stages. Routes outside First Mate and the basic host
status reads are unavailable.

Each run creates a fresh directory under ignored `build/first-mate-ios`. The
`fixture-current.json` manifest gives the URL, synthetic token, feature and
workflow IDs, sample project folder, and request log path. `requests.jsonl`
records request methods, paths, bodies, and timestamps, without authentication
headers. Stop the server with Control-C. Restarting creates a new isolated fixture.

The seeded feature contains three completed workflow steps, three Planning
documents, seven independent reviewers, and thirteen saved sessions. The
architect session has 235 messages for pagination checks. Both the implementation
handoff and a predecessor First Mate conversation remain accessible.

Launch the iOS Debug build with these arguments, using the manifest's `cwd` value
when creating a new feature:

```text
-HerdrUITestServerURL http://localhost:9196
-HerdrUITestAPIToken synthetic-first-mate-ios-token
-HerdrOpenFirstMate
-herdr.smartAlerts NO
```

The fixture credentials live only in launch arguments. They are retained when
the client reconnects and are not saved to Keychain. To prepare the dataset and
verify its saved-session reader without starting HTTP, use `--seed-only`.

Run the three First Mate UI suites on an available simulator:

```sh
xcrun simctl list devices available
xcodebuild -project herdr-harness-ios/herdr-harness-ios.xcodeproj \
  -scheme herdr-harness-ios \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -only-testing:herdr-harness-iosUITests/HerdrFirstMateUITests \
  -only-testing:herdr-harness-iosUITests/HerdrFirstMateServerUITests \
  -only-testing:herdr-harness-iosUITests/HerdrFirstMateNavigationUITests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

Replace `SIMULATOR_UDID` with a device from the first command. The authenticated
UI case checks for the fixture before running and skips when it is absent; the
synthetic demo cases do not need a server. Simulator ad hoc signing is enabled
because the host-navigation case exercises a real Keychain save. An unsigned
simulator build can fail that save before navigation is reached.

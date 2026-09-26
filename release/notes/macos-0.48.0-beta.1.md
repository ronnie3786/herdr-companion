# Herdr Companion 0.48.0-beta.1

This release brings together PRs #64, #67, and #69 from one reviewed source revision.

## Mac HUD chats

Fresh chats select this Mac and its companion's declared default model. Machine and model overrides apply to the current draft. Enable **Create in main workspace**, choose the workspace once for that machine, then send to start the conversation directly there. Existing conversations keep their original routing.

Workspace creation preserves drafts, attachments, and confirmed pane identity through cancellation and uncertain responses. A failed recovery-state write prevents creation. Ambiguous local-machine identity requires an explicit choice.

## First Mate verification

Overview now names the tested revision and exact package-qualified gate set. Missing changed-package suites, omitted earlier passes, stale evidence, and unavailable source checks cannot claim full verification. Empty gate selections remain empty across refreshes and restarts; board refreshes detect source changes even without a workflow event. Delayed responses cannot restore an older green verdict after a downgrade.

## iOS source included

First Mate defaults to **All Machines** and combines features with their owning-machine labels. Single-machine filtering remains available, and actions stay on the feature's owning companion. The iOS changes are merged and verified in this source revision; this Mac update does not install an iOS build.

## Compatibility and installation

Install this preview through **Herdr Companion → Check for Updates…**, with **Include preview builds** enabled. The app is Apple Development-signed, distributed through the signed update feed, and is not notarized.

Workspace creation requires `quick-session-launch-options-v1`; verification requires `first-mate-verification-v1`. Install the matching companion 0.48.0b1 package and Pi integration separately to enable those server-backed features. Older companions retain ordinary HUD chats and show unavailable verification or upgrade guidance. The Mac updater does not install server packages, restart services, or update iOS.

## Check the changes

- In a fresh HUD chat, confirm the local machine and **Machine default**. Enable workspace creation, select its destination, send once, and inspect the new workspace chat. Continue an existing conversation and confirm the checkbox is absent.
- In First Mate Overview, inspect the named verification gates and revision. On a disposable test feature, omit a suite or advance the source revision and confirm **Partially verified** instead of green.
- After a separately distributed iOS build, check the default **All Machines** scope, offline-host state, single-machine filtering, and two hosts with matching feature IDs.

Automated source, native-unit, browser, and package checks are required before publication. Connected-device, accessibility, and live Pi-session checks remain post-install validation and are not implied by CI.

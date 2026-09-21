# macOS 0.25.0-beta.1

## Shorter computer segment labels in the sidebar

The Mac sidebar's computer segments now use the shorter labels **All**, **Work**, **Dev**, and **Studio**, in that order ([#20](https://github.com/ronnie3786/herdr-companion/issues/20), [#21](https://github.com/ronnie3786/herdr-companion/pull/21)).

- The segment bar takes less room, so switching between computers stays quick.
- Existing machine connections and selections are preserved; nothing needs to be reconnected or reconfigured.

## Compatibility

This release updates the Mac app only. The companion server, CLI, and Pi package are published separately, so install companion updates when you choose to. This change requires no server update and the shared API contract is unchanged.

## Install and verify

1. In **Settings → Updates**, turn on **Include preview builds** if it is off.
2. Choose **Herdr Companion → Check for Updates…**, review the update, and let Sparkle install and relaunch the app.
3. Confirm the sidebar's computer segments read **All**, **Work**, **Dev**, **Studio** in that order, and that your previously selected computer is still selected.

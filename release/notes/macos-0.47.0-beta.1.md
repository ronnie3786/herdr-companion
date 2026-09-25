# macOS 0.47.0-beta.1

## First Mate status colors

First Mate statuses now match the agent session HUD colors: red for Blocked, green for waiting on your direction, and yellow for Working, including the Dashboard and Agent view status pills. No companion server update or new setting is required ([#63](https://github.com/ronnie3786/herdr-companion/issues/63), [#65](https://github.com/ronnie3786/herdr-companion/pull/65)).

## Companion compatibility

This release updates the Mac app only. The companion server, CLI, and Pi package are published separately, and the Mac updater does not install or restart them. The status colors use existing companion data, so no companion update or new setting is required.

## Install and verify

In **Settings → Updates**, enable **Include preview builds** if needed, then choose **Herdr Companion → Check for Updates…** and let the signed feed install the preview. Open First Mate and compare its statuses with the agent session HUD: Blocked shows red, waiting on your direction shows green, and Working shows yellow in both Dashboard and Agent view status pills.

This preview is Apple Development-signed and distributed through the signed updater. It is not notarized.

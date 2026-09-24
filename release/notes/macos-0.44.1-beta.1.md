# macOS 0.44.1-beta.1

## HUD chat status and cost bubbles

HUD chat bubbles now use the same yellow running indicator and synchronized model and cost display as agent bubbles. The HUD chat label is unchanged, but the previous machine name and running-border treatment are replaced. Costs reflect the conversation usage reported by the companion ([#41](https://github.com/ronnie3786/herdr-companion/issues/41), [#44](https://github.com/ronnie3786/herdr-companion/pull/44)).

## Companion compatibility

This release updates the Mac app only. It uses the existing HUD chat support, so no companion update is required beyond what is already installed. The companion server, CLI, and Pi package are published separately, and the Mac updater does not install or restart them.

## Install and verify

In **Settings → Updates**, enable **Include preview builds** if needed, then choose **Herdr Companion → Check for Updates…** and let the signed feed install the preview. Open a HUD chat and confirm its bubble shows the yellow running indicator plus the current model and cost, matching the agent bubbles.

This preview is Apple Development-signed and distributed through the signed updater. It is not notarized.

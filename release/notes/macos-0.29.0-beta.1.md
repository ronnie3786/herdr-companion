# macOS 0.29.0-beta.1

## First Mate attention badge

First Mate now shows an attention badge in the Mac Chat sidebar when features across your configured computers need your direction or a decision ([#30](https://github.com/ronnie3786/herdr-companion/issues/30), [#33](https://github.com/ronnie3786/herdr-companion/pull/33)). It refreshes automatically using existing First Mate support, so the badge appears and clears as items move in and out of waiting states.

## Companion compatibility

This release updates the Mac app only. The badge works with existing companions advertising `first-mate-v1`; no companion server update is required. The companion server, CLI, and Pi package are published separately, and the Mac updater does not install or restart them.

## Install and verify

In **Settings → Updates**, enable **Include preview builds** if needed, then choose **Herdr Companion → Check for Updates…** and let the signed feed install the preview. Open **First Mate** and confirm the sidebar shows the attention badge while a feature is waiting for your direction or a decision, and that it clears once you respond.

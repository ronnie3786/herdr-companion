# macOS 0.44.0-beta.1

## Deleted files in PR Review

Deleted files in Mac PR Review now show a clear **Deleted** label and keep their contents collapsed by default. Choose **Show deleted content** to inspect the removed text or code, then hide it again ([#49](https://github.com/ronnie3786/herdr-companion/issues/49), [#52](https://github.com/ronnie3786/herdr-companion/pull/52)).

## Companion compatibility

This release updates the Mac app only. It uses existing PR Review support, so no companion update is required. The companion server, CLI, and Pi package are published separately, and the Mac updater does not install or restart them.

## Install and verify

In **Settings → Updates**, enable **Include preview builds** if needed, then choose **Herdr Companion → Check for Updates…** and let the signed feed install the preview. Open a PR Review that deletes a file and confirm the file row shows the **Deleted** label with its contents collapsed; use **Show deleted content** to reveal the removed text and hide it again.

This preview is Apple Development-signed and distributed through the signed updater. It is not notarized.

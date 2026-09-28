# macOS 0.60.0-beta.1

## Darker Glass and Haze backgrounds

The Mac app's shared purple **Glass** and **Haze** backgrounds are roughly 20%
darker. The same soft violet, rose and indigo dusk remains across the main
window, both HUDs and the First Mate chat window, at a deeper shade that helps
text stand out. Text, icons, status colors and controls keep their existing
colors, and the gradient shapes and softness are unchanged.

Existing Appearance controls are unchanged: **Glass**, **Haze behind the chat**,
Reduce Transparency and the First Mate light appearance all behave exactly as
before. This is Mac presentation only, so no new setting and no companion
update are needed.

([#86](https://github.com/ronnie3786/herdr-companion/issues/86),
[#91](https://github.com/ronnie3786/herdr-companion/pull/91))

## Compatibility and installation

This release updates the Mac app only. The companion server, CLI and Pi package
are published separately and are not installed by the Mac updater; install and
restart them separately on each machine where they are used. This appearance
change needs no companion update.

Install this preview through **Settings → Updates → Check for Updates…**, with
**Include preview builds** enabled. The app is Apple Development-signed,
distributed through the signed update feed, and is not notarized.

## Check the changes

- Open the main window over any desktop picture. The sidebar and pane show a
  deeper purple dusk while labels stay readable.
- Open both HUDs and the First Mate chat window. Their glass surfaces are darker
  with the same gradient shape and softness.
- Toggle **Glass** and **Haze behind the chat** in **Settings → General →
  Appearance**, and try Reduce Transparency in System Settings. Each option
  keeps its existing behavior.

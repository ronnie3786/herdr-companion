# macOS 0.58.0-beta.1

## Darker Glass and Haze backgrounds

The Mac app's shared purple **Glass** and **Haze** backgrounds are about 20% darker.
The same violet top-left, rose top-right and indigo-bottom dusk gradient remains,
just at a deeper shade across the main window, both HUDs and the First Mate chat
window. Text, icons, status colors and controls keep their existing colors, and
the established 4.5:1 reading-contrast checks still pass — primary, prose,
secondary and tertiary text now stand out more against every glass fill.

Gradient geometry, blur and saturation, HUD crop, glass levels, Haze height and
fade, image caching, and the opaque Glass off, Haze off, Reduce Transparency and
First Mate light appearances are unchanged. This is Mac presentation only, so no
new setting and no companion update are needed.

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
  deeper purple dusk, and labels stay readable.
- Open both HUDs and the First Mate chat window. Their glass surfaces are darker
  while the gradient positions and softness are unchanged.
- Toggle **Glass** and **Haze behind the chat** in **Settings → General →
  Appearance**, and try Reduce Transparency in System Settings. Each option
  keeps its existing behavior.

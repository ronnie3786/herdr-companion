# Herdr Companion 0.52.0-beta.2

## Dusk glass, as previewed

Herdr's glass now shows its own dusk backdrop through the sidebar, panes and HUD,
on any desktop picture: violet at the top left, rose at the top right, indigo
along the bottom. In 0.51 the glass let the desktop through with the standard
macOS window material, which flattens every wallpaper to a plain charcoal, so
the purple from the design previews never appeared.

- The sidebar and pane share one continuous backdrop. The HUD card has its own,
  rose at the top and indigo at the bottom.
- The backdrop is one image drawn once and stretched. Nothing blurs live, and
  the window no longer asks macOS to blur the desktop behind it.
- Text stays at 4.5:1 contrast or better over the brightest part of the dusk.
- **Settings → General → Appearance → Glass** turns it off, and **Reduce
  transparency** still draws opaque surfaces. Haze behind the chat is unchanged.

This build also includes everything in 0.52.0-beta.1, including skims.

## Compatibility and installation

Install this preview through **Herdr Companion → Check for Updates…**, with
**Include preview builds** enabled. The app is Apple Development-signed,
distributed through the signed update feed, and is not notarized.

The dusk glass needs no companion change. Skims still come from a companion
advertising `first-mate-skim-v1` (0.52.0b1 or later); the Mac updater does not
install companion packages.

## Check the changes

- Open the main window over any desktop picture. The sidebar and pane show the
  dusk, and every label stays readable.
- Open the HUD. Its card shows rose at the top and indigo at the bottom.
- Turn **Glass** off in Settings → General → Appearance. Every surface turns
  opaque right away.

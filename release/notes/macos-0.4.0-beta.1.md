# Herdr 0.4.0 beta 1

Mac HUD notes can now be resized. Open a note and drag its bottom-left resize handle. The app remembers the chosen size and keeps it within the display's available space.

The pane actions menu on Mac and iPhone now groups view, control, Pi session, pane, and close actions. Choose Pi session > Reload Pi extensions to send `/reload` to that pane.

The iPhone source includes note editing: open Notes, select a note, and tap Edit to change its title or rich text. Saves sync back to the Mac through the companion. Conflicting edits are rejected, and failed saves keep the draft open.

## Setup and compatibility

These changes use the existing notes and terminal-input APIs. A companion that already supports shared notes does not need a server update for this release. iPhone note editing requires building and installing the updated iOS app separately; this GitHub Mac update does not install it.

Use `/reload` when Pi is idle. It reloads the session's existing extension paths. Sessions launched with an explicit `-e` or `--extension` path still need to be exited and resumed from an updated installation when that path changes.

To install the Mac preview, enable Settings > App updates > Include preview builds, then choose Herdr > Check for Updates.

This personal testing preview uses Apple Development signing and signed Sparkle updates. It is not notarized.

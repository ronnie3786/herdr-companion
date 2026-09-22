# Herdr Companion 0.35.1-beta.2

## Stop repeated Git page reloads

- Fix a native document-identity bug that could repeatedly reload First Mate Git and return it to **Reading working tree…**, even when Git requests succeeded.
- Keep the existing workbench, selected diff, and scroll position during native refreshes of the same target. The correction also covers pane Git and Git pop-out windows.
- Real server, credential, feature, and workspace changes still load the appropriate document; authentication and navigation-origin restrictions are unchanged.

Open **First Mate → a feature → Git** and leave a diff open while feature refreshes continue. The initial loading screen should not repeatedly return. Use **Open Git in New Window** to check the same behavior in a pop-out.

## Compatibility

This is a Mac-only correction. Keep the existing companion server and web assets; no server update, installation, or restart is needed. First Mate Git still requires a companion advertising `first-mate-git-v1`.

This preview is signed for personal testing and is not notarized. Install it through Herdr Companion's existing signed update feed with **Include preview builds** enabled.

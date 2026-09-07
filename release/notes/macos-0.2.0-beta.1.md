# Herdr 0.2.0 Preview 1 for Mac

- Adds a banner for available app updates and **Herdr → Check for Updates…**.
- Adds automatic release checks and an optional preview channel in Settings.
- Verifies signed update feeds and downloads before installation.
- Lets you review the release, install it, and relaunch Herdr when ready.
- Updates the Mac app independently of the companion server.

This is the first preview with an in-app updater. Existing installations need
one initial installation of this release to receive future updates this way.
Machine connections and credentials remain local. Custom builds with a different
bundle identity require an operator-assisted data migration before switching to
the shared app identity.

Requires macOS 26 or later. Includes Apple silicon and Intel support.

This experimental preview is intended for personal testing. Its release workflow
uses Apple Development signing without Developer ID or notarization. Signed
update verification remains enabled; macOS may require approval on first install.

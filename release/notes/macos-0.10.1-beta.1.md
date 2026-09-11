# Herdr Companion 0.10.1-beta.1

## Sidebar color refinements

- Tab colors now stay in the left sidebar. The main chat, session header,
  composer, and workspace chat cards keep their normal theme backgrounds,
  regardless of the tab's assigned color.
- Color-key rows below **Filter chats** are twice as tall (56 points), with
  larger 15-point titles that follow the app's text-size preference. Click a
  color label to filter chats; click it again or **Show all colors** to clear.
- The pencil now focuses and selects the color label immediately, so typing
  edits the label rather than jumping to **Filter chats**. The editor preserves
  its caret during refreshes. Enter or clicking away saves; Escape cancels.

Existing color assignments, custom labels, and filtering behavior are retained.
Right-click a sidebar chat or tab and choose **Tab color** to assign or remove a
color. Right-click a color label for **Smart Rename**.

## Compatibility and installation

No server, Pi package, or iOS update is required. This Mac update does not deploy
or restart companion servers.

This is an experimental preview (build 25), Apple Development signed and not
notarized. Enable **Include preview builds** in Settings → App updates, then use
**Herdr Companion → Check for Updates…**. Normal macOS approval may be required
on first installation. App, Keychain, and update-feed identities are unchanged;
signed feed and archive verification remain enabled.

# macOS 0.23.0-beta.1

## Report bugs and request features from the app

- Help → **Report a Bug or Request a Feature…** (⌘⌥F) and Settings → General → **Feedback** open a report sheet. Choose Bug or Feature request, write a title and a description that is sent exactly as written, and attach up to six screenshots or documents with the file picker, drag and drop, or ⌘V for an image. Image metadata is removed before upload.
- **Included details** lists the environment fields that accompany the report (app version and build, macOS version, machine role, server capabilities). Machine names, hostnames, URLs, workspace labels, and tokens are never included.
- The companion server files a public GitHub issue through your authenticated `gh`, hosts attachments as assets of a rolling `issue-attachments` release so images render inline, and labels it. Leave **Start the automated fix pipeline** on to add the `herdr-autofix` label for the optional Code Factory daemon.
- After filing, the sheet shows the issue number with **Open on GitHub** and **Copy link**. A timeout followed by **Try again** never files a duplicate.

## Compatibility

Requires companion 0.23.0b1 or newer, which advertises `issue-reports-v1` with `code_factory.repository` set in its private configuration; older or unconfigured servers show an update or unavailable message and file nothing. Choose the companion that has that configuration in the sheet's machine menu. Everything else in this update is unchanged; no other server update or restart is required.

## Quick verification

1. Open Help → Report a Bug or Request a Feature…, attach one screenshot, expand Included details, and file a Bug.
2. Confirm the GitHub issue shows the verbatim description, the inline image, and the environment table.
3. Press Try again after a simulated failure (for example with the server stopped) and confirm only one issue exists once it succeeds.

Install through **Herdr Companion → Check for Updates…** with preview builds enabled.

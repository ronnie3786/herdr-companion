# Herdr Companion 0.10.0-beta.1

## Color-coded chat tabs

- Right-click a tab, sidebar chat, workspace chat card, or chat header and choose
  **Tab color**. Six muted accents—Lavender, Iris, Rose, Clay, Sage, and Slate—fit
  Herdr's charcoal and lavender theme. **Remove color** restores the normal look.
- All chats in a tab inherit its color, including new panes. Sidebar rows,
  Recents, workspace chat cards, and Pi chat backgrounds use matching tints.
  Selection remains distinct and text retains readable contrast.
- Active colors appear below **Filter chats** and above **New session**. Click a
  color label to show only matching chats; click it again or **Show all colors**
  to clear. Color filtering combines with search, machine, and recency filters
  and applies to priority sections as well as workspace groups.
- Click the pencil beside a color label to edit it inline. Enter or clicking away
  saves; Escape cancels. Right-click the label for **Smart Rename**, which prefers
  a Jira key and ticket title found in the grouped chats, without querying Jira.
  It uses the existing Quick Chat model and readable Pi conversations. Manual
  edits and changes to the group take precedence over late AI results.
- Assignments and shared color labels persist on this Mac across relaunches.
  They do not sync to other clients. Machine-scoped tab identities keep unrelated
  tabs separate. Numbered symbols support Differentiate without color.

## Compatibility and installation

No server, Pi package, or iOS update is needed for tab colors or filtering.
Smart Rename requires the existing headless agent API and a readable Pi
conversation. The Mac update does not deploy or restart companion servers.

This is an experimental preview (build 24), Apple Development signed and not
notarized. Enable **Include preview builds** in Settings → App updates, then use
**Herdr Companion → Check for Updates…**. Normal macOS approval may be required
on first installation. App, Keychain, and update-feed identities are unchanged;
signed feed and archive verification remain enabled.

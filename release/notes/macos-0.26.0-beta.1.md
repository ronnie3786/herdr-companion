# macOS 0.26.0-beta.1

## Configurable computer segments

The Mac sidebar now uses optional `sidebar_label` and `sidebar_order` values from the private machine roster instead of built-in name aliases.

- For one to three computers, labels and partial ordering come from the roster served by the **first saved companion connection**. Missing labels fall back to complete machine names; explicitly ordered machines come first, while ties and unordered machines retain roster order.
- The authenticated companion identifies its own unique configured roster record for that already-saved first connection, so its configured presentation works when the app connects through localhost or another origin alias. The server ID is not imported into app storage and never replaces the saved connection ID, URL, name, credentials, role, saved connection order, or selection.
- Other already-paired machines still require unique HTTP(S) origin matches. Missing self identity preserves older-server origin fallback; duplicate or unknown claims are never guessed, and the app never adds connections or infers presentation from names or roles.
- Existing machine identity and the selected machine are preserved. Zero machines remain hidden, and four or more machines keep the full-name menu.

Public defaults contain no private computer aliases. This behavior requires matching companion **0.26.0b1** runtime metadata. The Mac app updater does not install, configure, or restart companion servers.

## Install and verify

1. Update the companion that serves the first saved Mac connection by following its versioned-runtime update instructions; preserve the private configuration and state, and restart that companion after configuring arbitrary synthetic `sidebar_label` and `sidebar_order` values.
2. In **Settings → Updates**, enable **Include preview builds** if needed. Choose **Herdr Companion → Check for Updates…**, review the signed feed entry, then let Sparkle install and relaunch the app.
3. Save the first connection through a localhost URL while its synthetic configured roster record uses a different HTTPS origin. Use **Refresh** in the Mac app, or reconnect. Confirm the one-to-three-computer segments show the exact configured labels and partial order, nonprimary machines still match only unique origins, and the saved IDs, URLs, names, and previously selected machine remain unchanged.
4. Remove an optional label or order, restart the config-serving companion, and refresh again to confirm the complete-name and roster-order fallbacks. With four or more paired machines, confirm the existing full-name menu remains in use.

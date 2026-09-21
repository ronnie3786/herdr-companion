# macOS 0.26.0-beta.1

## Configurable computer segments

The Mac sidebar now uses optional `sidebar_label` and `sidebar_order` values from the private machine roster instead of built-in name aliases.

- For one to three computers, labels and partial ordering come from the roster served by the **first saved companion connection**. Missing labels fall back to complete machine names; explicitly ordered machines come first, while ties and unordered machines retain roster order.
- Runtime metadata applies only to already-paired machines whose HTTP(S) origins match uniquely. It never adds a connection or infers presentation from machine names, roles, or IDs.
- Existing machine identity and the selected machine are preserved. Zero machines remain hidden, and four or more machines keep the full-name menu.

Public defaults contain no private computer aliases. This behavior requires matching companion **0.26.0b1** runtime metadata. The Mac app updater does not install, configure, or restart companion servers.

## Install and verify

1. Update the companion that serves the first saved Mac connection by following its versioned-runtime update instructions; preserve the private configuration and state, and restart that companion after configuring arbitrary synthetic `sidebar_label` and `sidebar_order` values.
2. In **Settings → Updates**, enable **Include preview builds** if needed. Choose **Herdr Companion → Check for Updates…**, review the signed feed entry, then let Sparkle install and relaunch the app.
3. Use **Refresh** in the Mac app, or reconnect. Confirm the one-to-three-computer segments show the exact configured synthetic labels and partial order, and that the previously selected machine remains selected.
4. Remove an optional label or order, restart the config-serving companion, and refresh again to confirm the complete-name and roster-order fallbacks. With four or more paired machines, confirm the existing full-name menu remains in use.

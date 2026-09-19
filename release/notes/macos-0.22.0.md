# Herdr Companion 0.22.0

## Quieter chat activity

- Enable **Group all Clanking activity** in **Settings → General → Chat** to collect thinking, tool calls, and interim assistant commentary into one collapsed disclosure per turn. The final answer appears once the agent finishes. The option is off by default, and expanding the disclosure keeps all activity available. Errors and input requests remain visible. Older Previous chat excerpts keep their existing presentation.
- HUD Clanking stays collapsed until you expand it, including when a tool fails. Its disclosure follows the main chat presentation.
- Running HUD chats show the same yellow border as working agent bubbles, both when collapsed and when open.

## HUD Smart Rename

Right-click a HUD chat bubble and choose **Smart Rename** for a short title based on its conversation. Titles are saved on this Mac and retained when reopening the conversation from history.

## Git and sidebar navigation

- Choose **Open Git in New Window** from the Git tab to keep a separate, resizable view of that pane's repository. Switching chats in the main window leaves the Git window on its original pane and machine.
- The sidebar date filter now uses **All**, **Today**, and **Recents** segments. Recents still lists the 20 most recently active chats.
- With one to three configured machines, machine selection uses segments, including All. Four or more machines use a dropdown. Manage Machines remains available in the sidebar footer.

## Compatibility and installation

This stable-channel update preserves the Settings categories, App Shots, and update controls introduced in 0.21.0. It changes only the Mac app, keeps the existing server API contract, and requires no companion server update.

Choose **Herdr Companion → Check for Updates…**, review the update, and let the signed updater install and relaunch the app.

This build uses Apple Development signing and is not notarized, matching the existing release configuration.

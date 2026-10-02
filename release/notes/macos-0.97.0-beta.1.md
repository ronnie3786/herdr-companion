# macOS 0.97.0-beta.1

Preview channel, build 147.

A tidier chat title bar. The title, star and status stay on the left. Everything else now lives in one **⋯** menu on the right, next to Herd Pulse and the connection pill.

- **The ⋯ menu in a chat** has View (Chat, Terminal, Git, Skills), **Prompt History…**, **Summarize Session…**, the Pi session and Focus on Mac actions, pane actions, **Go to** (Active Work, Fleet, Activity), **Ask Agent…**, and **Close pane** last. Other screens get the same menu with **Go to** and **Ask Agent…**. The View menu shortcuts are unchanged (⌘2, ⌘3, ⌘5–⌘9).
- **Removed:**
  - the segmented Chat/Git/Workspace/Active Work/Fleet/Attention/Activity picker;
  - the separate Prompt history, Summarize, Focus on Mac and Agent buttons;
  - the 30-second response brief, replaced by skims;
  - the Workspace overview screen, with View ▸ Workspace Overview (⌘4) and the sidebar's **Open workspace** items;
  - the Mac attention deck, with View ▸ Go to Attention (⌘1). The iPhone and iPad app keeps its attention screen.
- **Still works:** creating workspaces from the sidebar or **File ▸ New Workspace**, and Focus on Mac from the ⋯ menu and sidebar context menus.
- On launch the app deletes the saved brief settings and its `response-briefs-v1.json`. Back and Forward entries for the removed screens are dropped.
- **Agent control:** `ui.open` accepts pane, First Mate and HUD chat targets only, and `ui.segment` no longer offers `workspace` or `attention`.

The app needs no companion update. Companion **0.81.0b1** removes the matching response-brief API and CLI choices; install it separately on each machine. The signed Mac updater installs only the app.

To try it, turn on preview builds and choose **Settings → Updates → Check for Updates…**. Then open a chat and click **⋯** at the right of its title bar.

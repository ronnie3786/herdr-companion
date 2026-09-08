# Herdr for Mac 0.4.1 beta 1

- Restore New note in the compact HUD note stack and when no notes exist. Open note cards also have a New note button. File → New Note (Shift-Command-N) opens a fresh note even with the HUD hidden.
- Right-click a chat in the sidebar, a HUD session bubble, or the chat header and choose Copy workspace pane ID.
- Click the title above the chat messages to edit the shared pane title. Save applies the name across connected clients; Cancel leaves it unchanged.

This Mac update uses the existing companion API and does not require a server or iPhone app upgrade. Remote iPhone notifications require APNs credentials configured in the private TOML on each session-owning companion. Mac local notifications alone do not confirm remote push delivery.

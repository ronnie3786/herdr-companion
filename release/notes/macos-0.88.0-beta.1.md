# Herdr Companion 0.88.0 preview

Watchers is a new destination below PR Review in the sidebar, also available with Command-9. Original avatars and smart-chip descriptions appear in a responsive purple Glass/Haze card grid, with filters, search, machine availability and the next routine to wake.

Create a watcher in the manual editor or use the focused agent builder. The builder asks for clarification, shows its draft and execution steps, and lets you inspect scripts and upcoming fires before activation. Follow actual step progress, past runs, logs and the separate Watcher inbox. Changes to an existing watcher are staged for review and preserve its history when applied.

Requires companion 0.75.0 beta 1 or newer with `HERDR_WATCHERS_ENABLED=1`. This release executes scripts, gates and Watcher inbox delivery. Scheduled agent, Slack and system-notification steps can be drafted but cannot execute yet. Watcher dry runs execute scripts and may cause their own external effects; Cronboard import previews execute nothing.

Install the companion package separately under a restart-capable supervisor. The signed Mac updater installs only the app; it does not install companion packages, enable Watchers or migrate Cronboard jobs. Existing clients remain compatible, and older companions show their availability in Watchers.

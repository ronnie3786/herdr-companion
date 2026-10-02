# macOS 0.98.0-beta.1

Preview channel, build 148.

Watchers now matches its approved design. Cards, avatars and smart chips use the prototype's measurements, so the grid reads the way the design reference did.

- **Cards:** the status row, avatar, name and "who" line sit on the design's spacing. Summaries keep one even line height whether or not a line holds chips. Cards in a row share one height, and the actions sit on a quiet divider with **Run now** emphasized.
- **Chips:** schedule, script, skill and agent chips use their own tints. The agent chip shows First Mate's small face, the script chip a terminal prompt, and inbox, project and computer chips stay neutral.
- **Avatars:** faces are opaque and fill their circle or squircle. Resting watchers dim with a "z" badge, a working run shows a mint ring just outside the face, and a watcher that needs you shows a rose "!". The gauge needle and metronome arm now draw at their intended angles.
- **States:** a running card shows "Sol is running docs-check" with a slim step bar. Resting cards say "I'm resting until you wake me.", and drafts say they are not scheduled yet. Next runs read "in 8 min", "Today at 6:00 PM", "Tomorrow at 2:00 AM" or a weekday.
- **Screen:** **Inbox** and **New watcher** move to the title bar. Below the header sit the filters, search, the next-to-wake (or working-now) pill, a "Resting" divider and a two-line create prompt. Spacing and type scale at the design's narrow and wide breakpoints.

This build also contains everything in 0.97.0-beta.1. If you skipped that preview: the chat title bar now keeps its title, star and status on the left and puts everything else in one **⋯** menu. The segmented scope picker, the 30-second response brief, the Workspace overview screen and the Mac attention deck are gone. On launch the app deletes the saved brief settings.

The Watchers changes are Mac-only and need no companion update. Companion **0.81.0b1** removes the matching response-brief API (see 0.97.0-beta.1); install it separately on each machine.

With preview builds enabled, choose **Settings → Updates → Check for Updates…**, then open **Watchers** in the sidebar (**Command-9**).

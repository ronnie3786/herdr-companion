# macOS 0.54.0-beta.1

## First Mate chat window (preview)

A new standalone **First Mate** window runs beside the main window. Turn it on in
**Settings → General → First Mate chat window (preview)**, then open **Window →
First Mate** (⇧⌘F). It is off by default, and the current First Mate screen is
unchanged.

- **One conversation list for every machine.** Each feature has an emoji avatar,
  its latest message (in the skim's words when one is ready), and a status in its
  own color: Blocked, Your turn, Ready for review, or the working step
  (Planning, Building, In review…), which breathes while it works. A colored dot
  shows only when a feature needs you *and* has a new message.
- **Chats keep the skim style.** First Mate replies sit in dusk-glass bubbles with
  the one-sentence skim, dotted phrases that open the original, and **Full
  reply**. Rating and copy stay on each reply. Feature and agent names become
  tinted mentions that open their chat or the inspector, and documents a
  message names show as cards that open the Documents tab.
- **The composer** tags a feature or crew member with `@` and sends a readable
  mention link. Hold the mic to talk; letting go sends. When a skim offers
  suggested replies and the feature needs you, they appear as chips.
- **My First Mate** shows a live summary of what needs you and what is moving,
  with hover cards for each feature. Its composer starts a new feature with your
  text as the goal.
- **The inspector** is the same Overview, Agents, Documents and Workflow
  inspector, with its own tab and selection. Below 1140 pt it floats over the
  chat; below 760 pt the list becomes a rail of avatars.
- The window has its own selection, tabs and drafts, so choosing a chat there
  never moves the main window. Reading a chat in either window clears its dot.

## Dock badge

The Dock icon now counts the First Mate conversations that need you and have a
new message, across every machine, and stays current with every window closed.
Its Dock menu lists up to five of them; choosing one opens the chat window on it
(or the First Mate screen when the preview is off). Turn it off in **Settings →
General → Show First Mate count on the Dock icon**; it is on by default and
independent of the preview window. While it is on, it replaces the unread-alert
count on the icon. The First Mate badge in the main window's sidebar uses the
same count.

Also: resource chips now say "1 agent" and "1 document".

## Compatibility and installation

Read markers, labels and the light fleet summary need companion **0.54.0b1** or
newer, advertising `first-mate-fleet-v1`. Against an older companion the window
still works from the existing feature list: every conversation that needs you
counts as unread, and emoji are picked on this Mac. The Mac updater installs only
the app; install and restart the companion package separately on each machine.

Install this preview through **Settings → Updates → Check for Updates…**, with
**Include preview builds** enabled. The app is Apple Development-signed,
distributed through the signed update feed, and is not notarized.

## Check the changes

- Turn on the preview setting, press ⇧⌘F, and open a feature with a dot. The dot
  clears once you have read its newest message, in this window and in the main
  window's First Mate screen.
- Type `@` in a chat's composer and pick a feature; the sent message shows it as
  a mention you can click.
- Check that the Dock icon shows the count and that its Dock menu opens a
  conversation.

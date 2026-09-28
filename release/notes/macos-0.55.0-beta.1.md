# macOS 0.55.0-beta.1

## First Mate HUD

The **First Mate HUD** is a new floating panel with First Mate's face and your First Mate features under it. It is separate from the agent HUD, which is unchanged. Each HUD has its own switch and its own place on screen. Turn the First Mate HUD on or off under **View → Show First Mate HUD** or **Settings → HUD → First Mate HUD**. It is on by default and appears once a machine has First Mate.

- **Glance.** Each feature is an orb with its emoji, ringed by six steps in its status color:
  - blocked is rose;
  - your turn is orange;
  - ready for review is green;
  - working is gold.

  A flat dot marks a feature that needs you and has a new message. The count on First Mate's face is how many features need you. Past six orbs, the last becomes **+N**, but features that need you always keep their own orb.
- **Open the list.** Use the chevron, or click **+N**. Features hang from a lit line: the ones that need you first, then the moving ones in start order, each with its step and percent. With many moving features, three show and a summary row shows or hides the rest.
- **Hover** an orb or row to see where the feature stands: its latest update, six labeled steps, and its progress.
- **Read and answer.** Click an orb with a dot, or a row's speech bubble, to read the newest message. You can type a reply or hold the mic to talk. Reading clears the dot everywhere.
- **Open a session.** Click a row to open that feature, in the First Mate chat window when its preview is on.
- **Talk to First Mate.**
  - Click the face to type.
  - Press and hold the face to talk; letting go sends.
  - "What needs me?" gets a one-line answer.
  - Name a feature, as in "Receipt export: ship the iPhone fix", and the words go to that feature as your message.
- **Move and rename.**
  - Drag the face to move the HUD. The list opens toward whichever side has room.
  - Right-click a feature to rename it or change its emoji.
  - Esc steps back one layer at a time.

## Compatibility and installation

The HUD uses the fleet summary, read markers and labels from companion **0.54.0b1** or newer, which advertises `first-mate-fleet-v1`; no new companion release is needed. Against an older companion it falls back to the feature list:
- every feature that needs you counts as unread;
- steps show as unknown;
- emoji are picked on this Mac.

Install this preview through **Settings → Updates → Check for Updates…**, with **Include preview builds** enabled. The app is Apple Development-signed, distributed through the signed update feed, and is not notarized.

## Check the changes

- After updating, look for First Mate's face near the top-right of the screen. Hover an orb, then click the chevron to open the list.
- Click an orb with a dot. The message card opens, and the dot also clears in the First Mate chat window and on the main window's First Mate screen.
- Hold the face, say "What needs me?", and let go.
- Turn the HUD off with **View → Hide First Mate HUD**. The agent HUD stays as it was.

# First Mate chat window layout

The standalone First Mate window is also the destination for chats opened from the current First Mate screen, the Window menu, Dock menu, and First Mate HUD. These routes share one layout and one persisted conversation-list width.

## Conversation list

- Drag the divider between the conversation list and chat to resize it from 76 to 480 points.
- The chosen width is restored after relaunch. If the whole window becomes narrow, the visible list is temporarily constrained so chat retains at least 360 points; widening the window restores the chosen width.
- At widths below 220 points, the list becomes a compact rail containing only avatars and unread/status dots. Widening it to 220 points restores the header, search, titles, previews, and status labels.
- Expanded conversation titles wrap to two lines before truncating.
- The divider is keyboard focusable (Left/Right Arrow in 20-point steps) and exposes the same adjustment to accessibility tools. Command-K expands a compact rail to the minimum text width before focusing search.

## Inspector

The 360-point inspector always overlays the trailing side of chat. It never participates in the horizontal stack, so opening or closing it does not resize the conversation list or chat. Escape closes an open overlay and Command-I toggles it. Its slide transition becomes an immediate change when Reduce Motion is enabled.

The window keeps its existing 680 by 620 point minimum. At that minimum, sidebar constraint plus compact inspector sizing preserve usable chat and keep the inspector toggle reachable.

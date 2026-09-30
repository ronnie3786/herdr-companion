# First Mate chat window layout

The standalone First Mate window is also the destination for chats opened from the current First Mate screen, the Window menu, Dock menu, and First Mate HUD. These routes share one layout and one persisted conversation-list width.

## Conversation list

The list works like Telegram's: it is either an 80-point avatar rail or an expanded list between 260 and 480 points.

- Drag the divider to resize the expanded list. Dragging narrower than 260 points holds the list at 260 until the drag passes 170 points, then it snaps to the rail. Dragging the rail's divider past 170 points expands it to 260.
- The rail shows only avatars and unread/status dots, with names as tooltips. The expanded list shows the header, search, titles, previews, and status labels. Titles wrap to two lines before truncating.
- The chosen width is restored after relaunch. When the window is too narrow for an expanded list beside 380 points of chat, the list collapses to the rail; widening the window restores the chosen width.
- The divider is keyboard focusable (Left/Right Arrow in 20-point steps; the rail and 260 points are one step apart) and exposes the same adjustment to accessibility tools. Command-K expands the rail to 260 points before focusing search.
- The window's minimum width is 460 points: the rail beside the narrowest chat.

## Inspector

The 360-point inspector is a trailing column that extends the window. Opening it grows the window by 360 points to the right, sliding the inspector out from behind chat's trailing edge, so the list and chat keep their widths. Closing it gives the 360 points back. If the window is too close to the screen's right edge, it moves left as far as needed and returns when the inspector closes. While the inspector is open, the window's minimum width includes it.

A full-screen window cannot change size, so there the inspector opens inside the current width and chat narrows. With no earlier choice, a window 1280 points or wider opens with the inspector already inside it. Escape closes the inspector, and Command-I toggles it. With Reduce Motion on, the window resizes without animating.

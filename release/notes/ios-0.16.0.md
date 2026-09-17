# iOS 0.16.0 (39)

## Your saved HUD chats on iPhone and iPad

Open **Agents → HUD Chats** and select a companion machine to search and read its saved Mac HUD conversations. Continue a chat from your phone, or create a new saved HUD chat without opening a terminal workspace. The same chat is available in Mac **Chat history** on that machine.

- Browse older chats and full conversation history, including replies, tool activity, run status, and the original working folder.
- Choose a model, thinking level, and home or custom machine folder when creating a chat.
- Follow accepted runs without keeping the screen open. Closing the view or choosing New chat never deletes history or stops the server's work.
- Stop the latest run explicitly. A promoted chat opens its existing workspace pane instead of forking the conversation.
- Keep a rejected draft and refresh before retrying after a cross-device conflict. No automatic resubmission.

## Compatibility

Requires iOS/iPadOS 26 or newer and a paired, reachable companion with `hud-chat-v1`. The updated Mac preview provides live refresh of open saved chats. The companion remains the authoritative owner; selecting another machine selects another catalog rather than transferring a session.

Custom-folder submission additionally requires companion **0.16.0b1** or newer advertising `hudChatWorkingDirectory`. This fixes the server rejection of Mac requests containing `cwd`. Updating either native app alone does not update a companion server; install its package separately using the documented server procedure.

Accepted chat content and status are shared. Unsent drafts, custom-folder shortcuts, and local presentation settings are not synchronized.

## Build metadata

The intended signed build version is recorded in `release/ios.json`. Private native preparation supplies its `version` as `MARKETING_VERSION` and `build` as `CURRENT_PROJECT_VERSION` for the app and embedded widget, keeping contributor project defaults separate from distribution metadata. Signing inputs and machine connection details remain outside Git. A release note or metadata file alone is not evidence that a signed build was delivered.

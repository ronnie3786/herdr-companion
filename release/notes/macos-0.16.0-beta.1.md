# macOS 0.16.0-beta.1

## Saved HUD chats across Mac and iOS

- Open **Agents → HUD Chats** in the matching iPhone or iPad app to find, read, continue, or create saved HUD conversations. On Mac, use the HUD clock button's **Chat history** for the same machine.
- Open Mac conversations refresh when another device adds a turn. Replies check the saved thread before sending; concurrent writers cannot silently fork the conversation. Drafts stay available after a rejected send.
- Fix custom-folder HUD submissions being rejected immediately: the matching companion now accepts and validates `cwd` on the target machine. Updated clients explain when a server upgrade is required. Missing folders remain an explicit error instead of silently running from home.
- A saved conversation retains its original working folder across devices. Closing its view or choosing New chat never deletes it or stops an accepted run. Explicit Retry of an accepted failed turn stays in that saved conversation instead of leaving a hidden, unrelated thread.

## Compatibility and installation

Install the Mac preview through **Herdr Companion → Check for Updates…** with **Include preview builds** enabled. This preview uses Apple Development signing and is not notarized; signed update verification remains enabled.

Install the matching iOS build separately. Both apps must be paired with the same companion machine to see its chats; each machine owns a separate catalog. Unsent drafts, custom-folder shortcuts, and local HUD layout do not sync.

Custom-folder submissions require the separately released companion **0.16.0b1** or newer, advertising `hudChatWorkingDirectory`. Existing `hud-chat-v1` servers still support saved history and home-folder chats. The Mac updater does **not** install or restart the companion server, update Pi packages, or install the iOS build. Follow the companion release's independent update procedure on each relevant machine.

## Try it

1. Open an existing Mac HUD chat from **Agents → HUD Chats** on iPhone, selecting the same machine.
2. Send a reply on iPhone and reopen or watch that saved chat on Mac. Its next turn should appear without submitting the prompt again.
3. Start a new iPhone HUD chat and find it in Mac **Chat history**.
4. After separately updating the companion, choose an existing absolute folder on that machine and submit a new chat. Confirm its saved folder is shown on both clients. A missing folder should show an actionable error and retain your draft.

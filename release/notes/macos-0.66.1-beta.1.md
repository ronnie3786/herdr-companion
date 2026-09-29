# macOS 0.66.1-beta.1

## First Mate voice-send recovery

- A failed First Mate HUD send now keeps your transcription, even if the companion is unavailable before the conversation opens. The recovery card names the destination and offers **Retry send**, **Copy text**, and **Discard**.
- Retry keeps the original machine, conversation, message, and request ID to avoid duplicate delivery. Reconnecting never resends automatically, and another recording cannot overwrite an unresolved message.
- Closing the recovery card or hiding the HUD keeps the text while the app runs. Click the face to reopen it. Unsent recovery text is not retained across app relaunches.

## Companion compatibility

This update changes the Mac app only and requires no companion server update. Existing authentication and First Mate APIs remain unchanged. Companion servers, CLI tools, Pi packages, and iOS are not installed or restarted by this update.

## Install and verify

Install with **Settings → Updates → Check for Updates…**, with preview updates enabled. Hold the First Mate face, speak, and release to send. If the connection fails, confirm the text stays available in the recovery card; after reconnecting, use **Retry send** without recording again.

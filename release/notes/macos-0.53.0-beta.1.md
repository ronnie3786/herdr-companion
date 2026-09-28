# macOS 0.53.0-beta.1

## Voice dictation in First Mate chat

In Mac First Mate, the microphone beside the composer now starts click-to-stop
dictation. Clicking **Stop** finishes the recording, waits for a nonempty
transcript, appends it to the prompt, and automatically sends the composed
message once — no extra **Send** click.

- Voice-note recording moved under **More** as **Record a voice note**, which
  opens the unchanged recorder for recording, previewing, attaching or
  transcribing into the draft without sending.
- The routing change is First Mate only. Pane Chat, the terminal composer, the
  HUD, iOS and the web client keep their existing microphone and recorder
  behavior.
- The swap reuses the existing microphone permission, companion transcription
  service and First Mate send path, so no companion update is required.

([#81](https://github.com/ronnie3786/herdr-companion/issues/81),
[#82](https://github.com/ronnie3786/herdr-companion/pull/82))

## Compatibility and installation

This release updates the Mac app only. The companion server, CLI and Pi package
are published separately and are not installed by the Mac updater; install and
restart them separately on each machine where they are used. This dictation
change needs no companion update.

Install this preview through **Settings → Updates → Check for Updates…**, with
**Include preview builds** enabled. The app is Apple Development-signed,
distributed through the signed update feed, and is not notarized.

## Check the changes

- In a First Mate chat, click the microphone beside **+**, dictate, and click
  **Stop**. Confirm the transcribed prompt is sent exactly once without another
  **Send** click.
- Open **More** and confirm **Record a voice note** opens the recorder, and that
  pane Chat and the HUD still open their existing recorder from the microphone.

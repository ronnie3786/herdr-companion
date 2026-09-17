# macOS 0.17.0-beta.1

## Experimental 30-second response briefs

- Opt an individual Mac Pi chat into a native reading brief for each newly completed answer. Wide chats show an optional right-hand rail; narrow chats use **Open brief** to present the same content in a sheet.
- Choose the helper model and thinking level before **Create briefs for this chat** makes the first additional request. These controls are independent of the source chat, and enabling one chat does not enable another.
- Briefs expose descriptive links to exact, locally retained source slices, including comparison tables and code when the response contains them. **Full latest original response** always opens the unchanged answer; a selected older brief can also open its unchanged original.
- The helper receives the exact target answer and bounded recent context in a separate, tools-disabled Pi request. The generated summary can omit nuance, so the original remains authoritative.

## Compatibility and limits

Response briefs require companion **0.17.0b1 or later** advertising `response-brief-v1` on the machine hosting the selected source chat. Older companions show an upgrade message; the app does not fall back to a generic or action-enabled agent.

Opt-in is tied to the current Pi session and resets after `/new`. Generation occurs only while the Mac app is running. The first-experiment waiting queue is in memory, so unsubmitted entries can be skipped if the app quits; accepted requests retain durable receipts, and explicit regeneration remains available for the latest answer. Briefs are Mac-only, locally cached, and not synchronized.

## Install safely

In **Settings → App updates**, enable **Include preview builds**, then choose **Herdr Companion → Check for Updates…**. Review the update, confirm installation, and let Sparkle relaunch the app. Signed update verification remains enabled.

This preview uses Apple Development signing and is **not notarized**. It may require normal macOS approval on first installation; do not disable Gatekeeper or other protections.

The Mac updater does not install companion packages, switch or restart server services, or update iPhone clients. Install the [matching companion package](https://github.com/ronnie3786/herdr-companion/releases/tag/companion-v0.17.0-beta.1) separately using its documented versioned-runtime, backup, verification, explicit-switch, and rollback procedure.

## Try it in a real chat

The live model call is user-initiated. Ask Pi for a harmless answer such as:

> Answer only; do not run tools or change files. Compare arrays and sets in a small Markdown table, then include a short Swift code example that removes duplicates. End with one caveat about preserving order.

Open **Show brief** (or **Open brief** in a narrow window), select the helper model and thinking level, and then choose **Create briefs for this chat**. Check that the generated card offers descriptive comparison-table and code details, each opening verbatim lines from the original, and that **Full latest original response** shows the complete unchanged answer. Send one more message to verify automatic generation. Confirm another chat and a chat created with `/new` remain opted out, and that **Turn off for this chat** stops scheduling new briefs.

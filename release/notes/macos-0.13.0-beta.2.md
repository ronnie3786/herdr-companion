# Resize and end HUD chats

- **Resize the chat card:** drag Resize at the lower-left corner to change width
  and height. Right-click for Larger chat, Smaller chat, or Reset chat size.
  VoiceOver can adjust the size incrementally too.
- **Remember your size:** all HUD chat cards share the chosen size on this Mac,
  including after relaunch. The card stays within the current display and leaves
  space for notes and voice controls; the collapsed orb and bubbles are unchanged.
- **End Chat:** the dedicated button beside a chat's status confirms before
  stopping that HUD task and closing its bubble. Saved conversation history stays
  searchable; unsent drafts and attachments are discarded.
- **Safe closure:** ending during submission waits for the accepted run identity.
  Failed stops or unavailable machines keep the bubble available for retry.
  Other chats and their drafts are unaffected. A promoted terminal workspace
  session is never closed by End Chat.

## Try it

Open a HUD chat bubble, drag Resize to make the transcript wider or taller, then
collapse and reopen it. Choose End Chat beside its status to close that one chat.
Find it later with the clock button's Chat history search.

## Compatibility

Mac-only update using the existing HUD chat, cancellation, and saved-history API.
No companion server, CLI, Pi extension, or iOS update is required beyond existing
`hud-chat-v1` support. The Mac updater does not deploy or restart the server.

This preview uses Apple Development signing and signed Sparkle updates. It is
not a notarized Developer ID release.

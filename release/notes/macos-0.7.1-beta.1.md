# Herdr Companion 0.7.1-beta.1

## Fix for overlapping chat text

Fixes the jumbled, overlapping Chat UI introduced in 0.7.0-beta.1. Messages now wrap at their actual displayed width and reserve the correct height, keeping paragraphs, tool cards, and following messages separate.

The correction applies to native selectable text in the main chat, HUD, code blocks, and previous-session chapters. Text selection, Copy, and Quote & comment remain available.

Regression tests reproduce the original overlap and check layout at multiple window widths, default and large text sizes, and during streaming/finalization. Separate tests ensure that speculative text measurements cannot change the visible text's wrapping or selection.

## Update and verify

With preview builds enabled, choose **Herdr Companion → Check for Updates…**. Reopen the affected conversation and resize the window narrower and wider. Messages should remain clearly separated; selecting and copying text should still work.

Mac-only patch; no server, Pi-extension, or iOS update is required. Existing chats, notes, connections, and application identity are unchanged.

Experimental preview, signed for personal testing and not notarized. Signed update verification remains enabled.

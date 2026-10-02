# Companion 0.78.0-beta.1

Fixes missing skim reply suggestions in Main Chat, First Mate, and HUD chats. Concrete declarative offers and next-step statements now survive source validation, while unsupported suggestions, refusals, and work already underway remain excluded.

The new `skim-v5` generation refreshes stale cached skims once for the latest recent replies in live First Mate and HUD conversations. Main Chat uses the new generation when requesting a skim. Empty valid action lists do not cause repeated inference. Existing histories and original reply text are preserved.

Use Mac **0.93.0-beta.1** or newer for the native cache refresh fix. The API remains compatible with older Mac and iOS clients; iOS ignores optional reply actions. Skims still use the configured model and minimum reply length (80 words by default).

Build and install the wheel in a new versioned runtime following the server update procedure in `herdr_harness/README.md`. Preserve private configuration and state, update matching CLI/Pi components, and restart affected services only after active work is safe. The Mac updater does not install this package.

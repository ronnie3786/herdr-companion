# Companion 0.79.1-beta.1

Improves smart reply chip reliability in Main Chat, First Mate, and HUD chats. When the skim model proposes options that all fail formatting or source validation, the companion can make one bounded attempt to repair those options while keeping the original useful summary. A repair must still refer to the original offered next step and pass the same source checks. Failed repairs leave the original skim available.

Informational replies, valid empty option lists, and skims that already have a usable option do not trigger repair. The new `skim-v6` identity refreshes eligible cached replies once through the existing bounded refresh queue. Diagnostics report fixed validation reasons without recording private reply text.

Use Mac **0.93.0-beta.1** or newer for the native cache refresh behavior. This server patch does not require another Mac app update. Older Mac and iOS clients remain compatible; iOS ignores optional reply actions. Replies below the configured skim threshold still appear in full.

Install the wheel in a new versioned runtime following the server update procedure in `herdr_harness/README.md`. Preserve configuration, state, authentication, and matching CLI/Pi components. Restart affected services only after active work is safe. The signed Mac updater does not install this package.

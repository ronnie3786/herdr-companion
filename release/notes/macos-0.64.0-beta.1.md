# macOS 0.64.0-beta.1

Right-click a feature conversation in the standalone First Mate window, its compact sidebar avatar, its conversation header, or its transcript and choose **Archive feature…**. Confirming removes it from the active feature list and badges. Saved First Mate session rows also offer the owning feature's archive action. History remains available, and running work continues. To restore a feature, open First Mate in the main window, select its machine, and enable **Show archived**.

The Overview hides Pull Requests until a saved PR exists, then uses the same card styling as Current Focus. Verification is removed from Overview. Usage shows readable model names such as **GPT-6 Sol** and **Claude Sonnet 4.5**, without provider routing prefixes. The goal shows a short plain-text outcome, preferring a named Goal or Objective in older briefs and keeping the complete original brief in server state.

First Mate write requests now allow 24 hours for a response. A request timeout does not establish that the server rejected the message; check the conversation before resubmitting.

## Companion compatibility

Archiving requires the existing **first-mate-archive-v1** capability. No server update is needed for the Overview or HTTP timeout changes.

Companion **0.64.0b1**, published separately, increases newly dispatched coordinator turns to a 24-hour inactivity budget and a seven-day absolute ceiling. Activity renews the inactivity budget. Existing explicit private settings and persisted job budgets remain authoritative. The Mac updater installs only the app; install and restart the companion separately to adopt its new execution defaults.

## Install and verify

Use **Settings → Updates → Check for Updates…** with preview builds enabled. In the standalone First Mate window, right-click an unused feature and archive it. Verify that its row disappears, and that archiving another feature keeps the current conversation selected. Open an Overview with no PR to see the quieter layout; the Documents section still offers its empty-state guidance.

This preview uses the existing Apple Development signature and signed update feed. It is not notarized.

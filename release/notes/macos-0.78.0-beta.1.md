# Herdr Companion 0.78.0 beta 1

- Open a saved agent session in First Mate to see user bubbles, collapsed Clanking activity, and final responses using Chat's timeline. Running conversations refresh automatically, and loading states explain when history or the next saved response is still pending. The viewer has no composer.
- Feature coordinators are now Second Mates, with Feature lead as the explanation. The primary cross-feature assistant remains First Mate.
- Research Scout is an explicitly requested specialist for ticket, API, and platform research. Each host supplies its own model pin and private instructions. Missing configuration blocks that specialist instead of substituting another model.
- Managed First Mate sessions no longer change Pi's shared auto-compaction preference. They retain their own handoff policy, while ordinary Pi conversations keep automatic compaction.

Install companion 0.70.0b1 separately on each host for refreshed saved-session data, Research Scout routing, and the compaction isolation fix. After updating a companion, restore Pi's auto-compaction preference if an earlier version disabled it and reload existing ordinary Pi sessions. Per-model thresholds and company research instructions belong in private configuration.

The Mac update does not install companion packages or update the iPhone/iPad app.

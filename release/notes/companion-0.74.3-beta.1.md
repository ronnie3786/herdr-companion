# Companion 0.74.3 beta 1

Adds a private `first_mate.usage_enabled = false` recovery switch for hosts where
historical usage accounting delays opening First Mate. Cost totals become
unavailable while conversations and saved sessions remain accessible. History is
preserved and accounting can be restored after restarting with the default `true`.

Existing Mac, iOS, web, and Pi clients remain compatible. This is a companion-only
update. Install the wheel in a new versioned runtime, preserve private configuration
and state, and restart only the affected companion after a consistent backup.
See `docs/first-mate/usage-recovery.md` for verification and the follow-up plan.

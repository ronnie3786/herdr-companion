# Restoring access when usage history makes reads slow

If First Mate's fleet and runtime health respond but feature lists or chats time
out, whole-session usage accounting may be delaying request-time reads. A healthy
scheduler alone does not establish that the conversation routes are responsive.

For immediate recovery, set this in the affected computer's private configuration:

```toml
[machines.desktop.first_mate]
usage_enabled = false
```

Use the configured machine ID, validate the configuration, and restart only its
companion service at a safe boundary. The default is `true`. The equivalent process
setting is `HERDR_FIRST_MATE_USAGE_ENABLED=false`.

This switch skips usage transcript parsing and historical path resolution for
accounting. Usage and cost report **unavailable**, including assignment subtotals;
unknown cost is never represented as a confirmed zero. Conversations, the saved
session catalog, transcripts, and workflow state are preserved. Session opening
still performs its ownership and path validation. Restoring `true` and restarting
restores accounting from the retained history. Existing native clients need no
update.

After restart, verify authenticated feature list, lead, chat, overview, details,
and saved-session reads on a populated host. Check that invalid credentials are
still rejected and that active detached workers survive the service restart.
This switch does not bound all storage or verification work and is a temporary
availability measure.

## Follow-up stability work

- Move usage aggregation off interactive reads, with one bounded refresh per
  source, cached results, and explicit stale/unavailable states.
- Maintain incremental session and job indexes instead of repeatedly scanning
  complete history. Preserve identity checks and accounting coverage.
- Add populated-history latency and concurrent-reader regression coverage, plus
  endpoint latency monitoring separate from scheduler health.
- Bound optional read enrichment and retain a recovery switch, so an overloaded
  accounting component cannot prevent access to conversations.

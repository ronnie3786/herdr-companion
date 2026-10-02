# Companion 0.76.1 beta 1

First Mate list, chat and saved-session reads no longer synchronously rebuild
historical cost and token totals. One bounded background worker refreshes usage;
cold reads report unavailable totals, and failed or overdue refreshes retain
honestly partial coverage. Saved-session pages use bounded memory, and started
sessions can be discovered without usage accounting.

Restores the private `first_mate.usage_enabled` recovery switch alongside the
0.76 companion features. The effective switch and refresh state are visible in
First Mate capabilities. Cache validation now handles rewritten files, concurrent
readers and transient failures without losing session history.

Existing native, web and Pi clients remain compatible. Install the exact tested
wheel into a new runtime, preserve private configuration/state and detached
workers, and verify populated-history reads before enabling accounting. The Mac
updater does not install this package. See the usage-accounting recovery runbook
for staged rollout, freshness semantics and rollback.

# Companion server 0.65.1 Preview 1

- Restore saved Pi conversation history that was hidden by Herdr's small live checkpoint or by using Pi's compacted model context as the displayed transcript.
- Preserve earlier prompts, responses, and tool activity on the exact selected branch, without changing Pi's context usage or duplicating live events.
- Keep private agent setup, hidden extension state, signatures, and large binary payloads out of reader history.

Install this companion server package separately on each machine that owns Pi sessions. Existing Mac, iPhone, and browser clients are compatible; no Mac app update or restart of ordinary running Pi sessions is needed. The Mac updater does not install this server package.

After updating a server, reopen an affected chat or reconnect. Scroll up; on Mac, use **Show earlier rows** to reveal older loaded messages. Compaction no longer limits retained readable history. Deleted, ephemeral, invalid, or unreadable saved sessions retain the available bridge transcript; they cannot be reconstructed from missing data.

See `docs/pi-readable-history.md` for behavior and limits, and `herdr_harness/README.md#update-the-server` for staged installation, verification, backups, and rollback.

# Companion 0.26.0 Preview 1

## Private machine presentation metadata

Private machine configuration now accepts optional, validated `sidebar_label` and `sidebar_order` settings, exposed as `sidebarLabel` and `sidebarOrder` in the authenticated roster and private native bootstrap. Labels must be trimmed, nonempty, single-line text within the documented limit; order values must be nonnegative bounded integers. When the selected server machine exists uniquely in the public roster, the authenticated response also includes its stable configured ID as `localMachineId`. It is allowlisted identity metadata, not a token. These fields affect presentation only and do not change machine identity, credentials, selection, or connection setup. Public defaults contain no private computer aliases.

Matching Mac **0.26.0-beta.1** reads this metadata from the first saved companion connection. It uses the explicit self identity only for that already-saved primary connection, allowing localhost or another origin alias to receive the configured presentation, while nonprimary machines still require unique origin matches. Missing self identity preserves older-server origin fallback; duplicate or unknown claims are never guessed. Saved IDs and URLs are not rewritten and no connections are imported. Older clients safely ignore the additive fields. The signed Mac updater never deploys this companion package.

## Safer Code Factory planning and correction

Code Factory now preserves the original issue body and attachment context through planning, records requirement traceability and assumptions, requires independent requirement-by-requirement review and a configuration-variation assessment, and enforces the corresponding merge gates. Corrective review can send explicit replan feedback, while human retry can start again from the current issue description. Legacy in-flight plans require a fresh assessment before continuing under the hardened contract.

## Install and verify

Follow the repository's server update procedure: build or install this exact package in a new versioned Python 3.11+ runtime, take a consistent backup, and preserve the private configuration, credentials, state, and previous runtime for rollback. Validate the packaged installation and private configuration before explicitly switching each intended service. Update the matching Herdr CLIs, Pi package path, and any enabled workers while preserving their data, flags, schedules, and unrelated packages.

After switching, verify authenticated health, terminal connectivity, stored data, Pi integration, and each enabled worker before retiring the prior runtime. Configure arbitrary synthetic `sidebar_label` and `sidebar_order` values, connect to that companion through localhost while its synthetic roster record uses another HTTPS origin, restart it, then use **Refresh** or reconnect in matching Mac **0.26.0-beta.1**. Confirm the exact label/order result, unchanged saved IDs, URLs, names, and selected machine, unique-origin matching for nonprimary machines, and complete-name/roster-order fallbacks when fields are absent. These are verification steps, not claims that a rollout has already been performed.

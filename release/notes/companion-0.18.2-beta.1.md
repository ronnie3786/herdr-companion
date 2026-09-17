# Companion 0.18.2 Preview 1

## Source-relative concise briefs

- The restricted `response-brief-v1` helper now receives trusted numeric limits computed from the required original response, while source text and optional context remain untrusted data.
- Generated visible content is limited to a direct takeaway, at most one essential caveat, and up to two short labels for exact-source details. The total stays within one quarter of the source under the shared policy counters and never exceeds 40 words.
- The request profile, schema, template identity, durable receipt ownership, and exact original remain unchanged. Existing brief requests and records are preserved.

The matching Mac skips helper requests for already-short answers and withholds old verbose cached cards. It does not automatically backfill them; choose **Regenerate this brief** explicitly for the selected source. Brief model and thinking configuration remain independent from the source chat, and per-chat opt-in is unchanged. Eligible generation remains an additional private, tools-disabled provider request.

## Matching components and safe update

Use companion **0.18.2b1** with macOS **0.18.2-beta.1** for the complete concise behavior. The signed Mac updater does not install this package, update its bundled CLIs or Pi extension, switch services, or restart a companion.

Follow the documented [server update procedure](https://github.com/ronnie3786/herdr-companion/blob/companion-v0.18.2-beta.1/herdr_harness/README.md#update-the-server): preserve the private configuration and rollback environment, take a SQLite-consistent backup, install the wheel in a new versioned runtime, verify it, and explicitly switch only the intended service. Publishing this package does not perform a rollout. No live provider-quality test is claimed.

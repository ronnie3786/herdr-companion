# Herdr Companion 0.41.0 Preview 2

This signed Mac preview retains the Agent Profiles interface and First Mate stability/recovery from Preview 1. It pairs with the separately installed Companion 0.41.0b1 to reduce redundant First Mate confirmations; the app update alone does **not** change an older server's behavior.

## First Mate with the matching server

- One clear human request can authorize an ordered sequence of planning, implementation and review stages. First Mate records the stages on the first human turn, shows each completed stage, and proceeds only to the next authorized stage without asking for a token confirmation.
- Background coordination can request evidence-checked recovery within an active authorized stage. When the advisor is inconclusive but the stopped writer, preserved source and external-effect receipts are verified, a fenced successor inspects the predecessor before acknowledging its next step or asking for a genuine decision.
- A pending human redirect, explicit internal human gate, live old writer, unverified external effect, failed backup or exhausted recovery budget still pauses. A still-running detached build with no trustworthy completion receipt is **not** replayed automatically. Existing blocked legacy features do not automatically unblock.

## Compatibility and setup

The native Mac API is additive and remains compatible with older companions; the new behavior requires Companion **0.41.0b1** and its bundled Pi extension on the machine executing First Mate. Install the server package separately using the [server update procedure](https://github.com/ronnie3786/herdr-companion/blob/main/herdr_harness/README.md#update-the-server) and keep private settings/state. Do not replace an app bundle over SSH; use **Herdr Companion → Check for Updates…** and Sparkle's signed feed. Preview updates require **Include preview builds** in Settings → App updates.

## Quick test

1. In First Mate, request planning, implementation and independent review explicitly in one sentence for a synthetic project. Check that completion of planning queues implementation without another message, with the original authorization retained on both stages.
2. In a second feature request planning only. Confirm that implementation does not start until directed.
3. Inspect **Workflow → Stability & recovery** for checkpoints; when an actual human decision or uncertain external effect exists, verify the feature still pauses and retains evidence.

This preview uses Apple Development signing and signed Sparkle updates. It is not notarized.

# macOS 0.18.2-beta.1

## Genuinely concise response briefs

- Long answers now produce a direct takeaway, at most one essential caveat, and no more than two short links to exact source slices.
- Visible generated text is source-relative: no more than one quarter of the source under the documented counters, with an absolute 40-word ceiling. Tables, code, and status inventories stay behind exact-source links instead of becoming another prose list.
- Short answers remain the shortest reading path and make no additional helper request. The full original response remains unchanged and available.
- Previously cached briefs that fail the new limits are withheld rather than displayed or automatically regenerated. Select the affected source and choose **Regenerate this brief** to make a fresh request.

Per-chat opt-in and the independently selected brief model and thinking level are unchanged. When enabled for an eligible answer, the helper remains an additional private, tools-disabled provider request containing the exact answer and bounded recent text context.

## Matching companion required

Install the [matching companion 0.18.2 preview](https://github.com/ronnie3786/herdr-companion/releases/tag/companion-v0.18.2-beta.1) on every machine where response briefs are enabled. The existing `response-brief-v1` request and schema remain compatible with saved receipts and records, but the updated server supplies the trusted source-relative limits needed for the complete behavior. The Mac updater does not install or restart companion services.

## Install safely

In **Settings → App updates**, enable **Include preview builds**, then choose **Herdr Companion → Check for Updates…**. Review the update and let Sparkle install and relaunch the app.

This preview uses Apple Development signing and is **not notarized**. It may require normal macOS approval on first installation; do not disable Gatekeeper or other protections. No live provider-quality test or server rollout is implied by this release.

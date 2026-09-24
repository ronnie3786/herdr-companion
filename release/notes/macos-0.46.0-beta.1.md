# Herdr Companion 0.46.0-beta.1

This release combines the compaction, First Mate, reporting, and PR Review updates.

- Chat shows a completion cue after compaction finishes, including when returning to a conversation. The cue clears after an accepted message and stays available after a failed send.
- First Mate responses have thumbs-up and thumbs-down ratings, reusable reasons, and optional notes. Saved feedback survives restart; drafts survive temporary companion outages.
- First Mate keeps feature links alongside documents and surfaces discovered pull requests in Overview and Documents. Add, copy, hide, and restore links without losing the feature's existing documents.
- Help > Report a Bug or Request a Feature includes optional Smart input and inline recording. Draft with AI fills editable report fields; only File report submits the reviewed report.
- PR Review saves local Markdown comments on selected code. Open Comments to edit, copy, show the saved lines, or open their GitHub revision. Comments remain private on this Mac until copied and posted manually.

## Companion compatibility

Install companion server 0.46.0b1 separately to enable First Mate ratings (`first-mate-feedback-v1`), feature links (`first-mate-links-v1`), and AI report drafting (`issue-report-draft-v1`). The Mac updater does not install the companion. Existing clients remain compatible; updated clients explain unavailable capabilities on older servers. Report drafting uses the companion's configured Pi default, and recording uses its configured transcription service.

Compaction cues and local PR Review comments use existing companion data. Local comments require the existing `pr-review-v1` capability and add no automatic GitHub publishing.

## Try the changes

1. Open a compacted conversation and send a message to clear its completion cue.
2. Open First Mate, rate a response, and visit Documents > Links to add a link.
3. Open the report sheet, enter a plain-language request in Smart input, and choose Draft with AI. Review the result before filing.
4. Select code in PR Review, choose Add comment, and reopen it from Comments. Open original revision follows the saved side and commit, even after the PR moves forward.

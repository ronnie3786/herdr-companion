# macOS 0.63.0-beta.1

PR Review and First Mate now share commit-aware Git comparisons. Choose the
earlier and later revisions, inspect changes from the target baseline, and use
unified or split layouts with optional line wrapping. Local Git views also offer
uncommitted changes. Large comparisons load individual file patches on demand.

New First Mate workflow steps retain their commit history. The timeline shows
the captured ending commit, with the remaining commits available on expansion.
Click a commit to open its exact workspace and comparison. Older steps without
captured history remain explicitly unavailable.

Ask AI and the guided PR review buddy receive the selected comparison, file and
viewer state. They can inspect other authorized commits and files on demand.
Historical review state stays separate from the current full PR.

Choose **Breeze through low-impact files** in the review buddy to hear one file
at a time. A file becomes Viewed only after narration finishes and the save is
confirmed. Pause to ask questions, then resume. Voice interruption is not enabled.

## Companion compatibility

Install companion **0.62.0b1** or newer on each host to enable comparisons,
workflow commit receipts and Git-aware questions. The signed Mac updater
installs only the app; the companion and matching Pi integration are separate.
Existing clients remain compatible, and this Mac retains the previous viewer
when connected to an older companion.

## Install and verify

Install through **Settings → Updates → Check for Updates…** with preview builds
enabled. In PR Review, change **Before** and **After**, ask about a changed file,
and open the review in a separate window. In First Mate, open Git and compare
commits, then select a commit from a newly completed workflow step. Breeze is
available for unviewed files ranked low impact and requires configured narration.

This preview uses the existing Apple Development signature and signed update
feed. It is not notarized.

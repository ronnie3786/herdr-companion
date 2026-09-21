# macOS 0.27.1-beta.2

PR Review now opens diffs and Ask AI context for changed files whose names contain `+`, spaces, percent signs, query punctuation, or Unicode characters. Empty and unavailable diff states also keep the selected file header anchored at the top of the pane.

## Compatibility

This release updates the Mac app only. It remains compatible with companions advertising `pr-review-v1`; no companion server upgrade is required.

## Try it

Enable preview builds in Settings → App updates, then choose **Herdr Companion → Check for Updates…**. Open **PR Review → Files** and select changed files with special characters in their names. Their native diffs and Ask AI context should load normally.

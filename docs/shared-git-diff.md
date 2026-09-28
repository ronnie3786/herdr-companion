# Shared Git comparisons on Mac

PR Review and First Mate Git share the same diff renderer and comparison contract.
The comparison is part of navigation and AI context, rather than a label added
to an otherwise unchanged patch.

## Comparing revisions

The **Before** and **After** selectors show the target baseline and the captured
feature history. Before cannot be newer than After. The default compares the
target baseline with the latest commit; opening a workflow commit compares the
baseline with that commit. Selecting two commits compares their exact trees, so
the left commit itself is not included as a new change. **Latest** returns to
the default comparison.

First Mate and pane Git also offer **Uncommitted changes** on the right. This
includes tracked edits and untracked files. **Working files** retains staging,
unstaging, and the existing repository controls. PR Review uses its prepared,
committed review checkout. Both renderers support unified, split, and wrapped
text. Binary and truncated patches remain explicitly identified.

The current comparison determines the file list. Files that were subsequently
removed from the final PR can still appear in an earlier comparison. Historical
Viewed marks in PR Review stay separate from the current full-PR Viewed state.

First Mate records the target branch merge-base separately from each workflow
step's start revision. This includes feature commits made before the first step
and preserves the original comparison when the target branch advances. Existing
features without capture records use the current target branch. Incomplete
historical records report unavailable when the original target cannot be determined.

## Workflow history

Each new First Mate workflow visit captures the repository revision before the
step runs and its revision when the step completes. It retains all observed
commits between those revisions for each exact recorded workspace. The workflow
shows the latest commit, with the full list available on expansion. A commit
opens that workspace and revision in Git, including in a detached Git window.

Older visits without captured revision evidence stay unavailable. Rewritten
history, missing worktrees, and a repository outside the captured scope are
reported instead of reconstructed from titles or timestamps. Histories are
bounded; any truncated workflow receipt is labeled.

## Questions and guided review

**Ask AI** carries the comparison, current file, display state, and any selected
text and line spans. Different comparisons of the same file have different
question sessions. A late response cannot replace a newer comparison. Answers
that cite another file in the displayed comparison offer **Show file** navigation.

The restricted Git question profile can inspect captured history, files, and
diffs on demand, including later commits within the captured feature history.
It receives a small viewer-state packet rather than all historical file
contents. Committed source is pinned by revision; uncommitted source is captured
for the question and checked against the displayed comparison. The existing
guided PR buddy uses the same inspection tool and validates navigation and
drawings against its selected comparison. Earlier answers never draw on newer
code. No Git question changes repository files.

## Breeze through low-impact files

In the current full PR, choose **Breeze through low-impact files** to hear one
unviewed low-impact file at a time. The buddy marks a file Viewed only after
its explanation finishes playing and the save is confirmed, then continues.
Pause before asking a question; resuming returns to the interrupted file.
Missing audio, an interrupted explanation, or an unsuccessful Viewed save
does not advance the queue. Historical comparisons do not auto-mark the current
PR. Voice interruption detection is not part of this mode.

## Compatibility and implementation

The companion advertises `git-comparison-v1` and the `git-question-v1` assistant
profile. Older clients keep the previous APIs. A newer Mac connected to an older
companion keeps the existing viewer and provides upgrade guidance for unsupported
questions. The Mac updater does not install the companion server package.

`git_comparison.py` resolves authorized tree pairs and their patches. The PR and
workspace adapters own repository authorization and revision freshness.
`git_inspection.py` provides bounded read-only discovery from a captured manifest.
The native `GitComparison` models and web comparison models carry the resolved
identity through requests, rendering, questions, and guided playback. The
`SharedDiffRenderer` remains the single rendering implementation used by the
web workbench and the bundled native PR bridge.

The API accepts `all`, `commit`, `range`, and (for local workspaces) `working-tree`
selections. Responses retain the authoritative PR base/head separately from
`comparison.before_sha` and `comparison.after_sha`. The resolved comparison ID
also incorporates mutable working-tree patch content. Full commit IDs must belong
to the server-authorized history; arbitrary revision expressions and reversed
endpoints are rejected.

Comparison history is limited to 1,000 commits and reports an explicit error
beyond that bound. Working snapshots are limited to 256 MiB. AI discovery pages
contain at most 100 files or commits, and individual source reads are bounded
to 400 lines and 24 KB. Large comparisons keep their complete file catalog and
load a selected file's patch separately when the aggregate patch is truncated.

Verification covers synthetic sequential commits, renames, deletions, working
edits, target routing, stale comparisons, on-demand inspection bounds, narration
completion, pause, failed Viewed saves, and renderer-bundle reproducibility.

# macOS 0.27.1-beta.1

PR Review keeps the header compact and gives the code diff the remaining window space. The changed-file sidebar has a bounded width, so it cannot crowd out the code. Preparing reviews show progress and a useful title before metadata arrives.

The Files tab opens a changed file automatically when preparation finishes. Native diffs show deleted text, support long code lines and scrolling, and refresh when the PR's head commit changes. Loading failures and files without a textual diff have explicit states. Switching files or review hosts cannot display an older in-flight response over the current selection.

Select code in the diff to use the existing Ask AI action. File filters, Guided order, viewed marks, Context, Agents, and Skills remain available.

## Compatibility

This release updates the Mac app through its signed updater. It works with companions advertising `pr-review-v1`; companion 0.27.0b3 is recommended for interrupted preparation recovery and Pi skill startup fixes. Companion servers are installed separately. PR Review uses the review host's existing global Pi settings and globally installed skills.

## Try it

Enable preview builds in Settings → App updates, then choose **Herdr Companion → Check for Updates…**. Open **PR Review → Files**, select a prepared review, and confirm that the code fills the area beside the changed-file list. Resize the window, switch files, and select code to open Ask AI.

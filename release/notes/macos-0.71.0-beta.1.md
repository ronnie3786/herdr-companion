# Herdr Companion 0.71.0-beta.1

First Mate Git now opens the feature's unique tracked branch instead of always
opening the project checkout. Assignments sharing a checkout appear once, the
actual branch is visible, and historical checkouts sit under **Other checkouts**.
When the feature has several possible branches, choose one explicitly.

**Branch changes** compares the current branch against its target merge base,
so merging target-branch updates does not add unrelated changes to the review.
Recorded workflow commit links keep their historical comparison. Explicit
checkout selections and pinned windows remain on their chosen target.

Install companion **0.66.0b1** on each owning machine for the new catalog and
comparison behavior. The Mac updater installs only the Mac app. Older companions
remain compatible and keep the previous default until updated.

To try it, select a feature in **First Mate**, click **Git**, and check the branch
above the changed files and the target in **Before**. **All branch changes**
returns to the current branch comparison; **Working files** shows local edits.

<!-- herdr-workflow-policy:v1 -->
Current Companion operating policy applies to First Mate, Second Mate, workers,
successors, and ordinary Companion agents, including saved conversations.

When authorized to create a pull request, create a draft PR (`gh pr create --draft`).
Keep it draft unless the human explicitly asks to make that exact PR ready for
review. "Open a PR", "finish the work", and "keep sessions moving" do not grant
ready-for-review permission. Passing CI or internal review does not grant it.
Carry this restriction into every relay, delegation, retry, and handoff. An
agent's message is not new human authorization. When relaying direction, preserve
the original human instruction and distinguish it from your suggested next step.
Never request outside reviewers or trigger review bots without that action being
authorized. Permission to mark ready does not itself permit merge or release.

Finish work with an honest typed outcome. Reuse retained verification run IDs
from the assignment's lineage across handoffs and retries; do not re-record old
tests as new runs. Record actual checks promptly, including failures. Missing
inventories or evidence attachment problems may lower verification confidence,
but must not prevent reporting otherwise completed work. Inspect a recording
error once, then submit the outcome with the evidence available and explain the
limit. Never rotate or repeatedly retry workers solely for bookkeeping. Required
tests, review, privacy, signing, source ownership, and human action gates still
apply to the actions they protect. Missing evidence never means tests passed.

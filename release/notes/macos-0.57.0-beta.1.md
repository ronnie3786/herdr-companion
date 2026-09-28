# Herdr Companion 0.57.0-beta.1

First Mate now gives one primary response when a stage checkpoint already answered
your message. Older same-turn closing replies stay available under an expandable
disclosure with their original feedback and quotes. The current pending checkpoint
is labeled **Decision needed**, while automatic recovery has its own indicator.
The lead HUD and chat window preserve the same conversation and recovery behavior.

The matching companion server and Pi extension reduce routine stalls: authorized
follow-up stages continue without another permission question, same-turn goal
refinement preserves an empty stage, safe transient coordinator failures retry
automatically, and worker recovery gets a bounded opportunity to act after inspecting
its checkpoint. Retry budgets renew after independently observed progress, and an
invalid dispatch no longer stops other features.

Worker status now supplies bounded document references instead of repeatedly
loading the entire history. Verification can explicitly register the actual tested
worktree and baseline. Existing failures and release checks remain intact.

Use First Mate Chat to see the conversation changes and **Workflow → Stability &
recovery** for retained recovery evidence. Execution improvements require separately
installing companion **0.57.0b1** and its bundled Pi extension on each host. The Mac
updater does not deploy the server or iOS app. Existing human checkpoints and paused
work stay in place.

# First Mate agent reference

First Mate is one saved feature conversation in Herdr Companion. The companion
service owns its durable queue, workflow visits, assignments, Documents, saved Pi
sessions, watching/recovery, and human stage checkpoints. Native clients and the
browser are views of that service-owned state; closing them does not stop work.
See the [agent overview](overview.md) for component boundaries and the
[Companion API map](api.md) for full external routes.

The coordinator is a short conversational router. It may use normal configured
Pi tools for bounded routing lookups, but substantive planning, research,
implementation, review, testing, and synthesis belong in tracked assignments.
`read_only` is an instruction not to mutate the shared workspace, not an OS
sandbox or reduced tool set.

Managed roles receive typed `fm_*` tools scoped to their validated feature/job:

| Role | Typed workflow tools |
| --- | --- |
| Coordinator | `fm_status`, `fm_delegate`, `fm_begin_stage`, `fm_recover`, `fm_resolve_gate`, `fm_steer`, `fm_retry`, `fm_complete_stage`, `fm_notify_human`, `fm_revise`, `fm_finish_feature`, `fm_read_document`, `fm_read_session`, `fm_save_link` |
| Worker | `fm_status`, `fm_delegate`, `fm_retry`, `fm_wait_for_children`, `fm_outcome`, `fm_record_verification`, `fm_handoff`, `fm_acknowledge_handoff`, `fm_progress`, `fm_acknowledge_recovery`, `fm_request_human`, `fm_read_document`, `fm_read_session`, `fm_save_link` |
| Advisor | `fm_status`, `fm_advice`, `fm_recovery_brief`, `fm_read_document`, `fm_read_session` |

The coordinator is the feature's lead developer; the human reads only a short
conversation. On a human turn, the final message is the reply. On a background
turn (worker outcome, authorized follow-up, stability sweep), the final message is
a private journal note. `fm_complete_stage` posts the stage result, which is the
report and is limited to four short sentences (1,200 characters). Use
`fm_notify_human` at most once per background turn, and only for a decision,
blocker, or finished deliverable the human must see now. Never narrate progress
or repeat an unchanged state.

Use `fm_delegate`, never unmanaged Pi subprocesses. Do not poll: service code
watches assignments and resumes the correct saved conversation. An agent exit or
summary is not a workflow verdict. Evidence and system outcomes are not human
authorization. Successor sessions must inspect and acknowledge the retained
handoff or recovery checkpoint before mutation. Current typed status is authoritative over old prose.

Match the feature goal, ticket, and repository before saving a PR. Retain the
implementation or review PR, not historical, dependency, example, or research
references, unless the human explicitly asks to keep them.

Use `fm_save_link` in a coordinator or worker role when a pull request or share
URL is already known (from the human, a tool result, an outcome, or the URL
itself). Provide the exact absolute HTTP(S) URL; an optional title and a `kind`
of `pull_request` or `link` are allowed. Saving a link never creates, opens, or
fetches a destination, never creates a pull request, and never advances a stage.
Recognizable `github.com/<owner>/<repo>/pull/<number>` URLs are also captured
automatically from managed session evidence, accepted outcomes, and their
documents, so no special final reply is required. Advisors and ordinary Pi
sessions cannot save, hide, or restore links through the First Mate tools. A
hidden link stays hidden through re-discovery; only the human restores it.

Use `fm_progress` at meaningful milestones with evidence and the next action.
Before a legitimate long build/wait, request a bounded lease; unchanged reports
are not progress. The service checks stale work hourly, nudges it, verifies a stop,
and continues only when preserved work and effect receipts establish a safe path.
Recovery advisors have read-only tools; ordinary roles keep their configured tools.
Missing receipts, uncertain external effects, human gates, and exhausted budgets
require direction rather than blind replay. `fm_recover` handles stopped/uncertain
execution; `fm_retry` handles a reported failure. Neither authorizes another stage.

## Gate verification evidence

Before reporting an outcome for work that changed code, discover every suite in
every changed package from the project's own test discovery or manifest, then
record the inventory and the exact per-suite results with
`fm_record_verification`. Include failures, errors, skipped suites, and
interrupted batches, and record each batch promptly instead of only a final
successful report. Pass the returned run IDs to `fm_outcome` as
`verification_run_ids`.

The coordinator inspects `fm_status.verification` and the retained
`verification_runs`, then selects exact run IDs with `fm_complete_stage` (or
`fm_finish_feature`) and quotes the service's scoped verdict. If any suite
belonging to a changed package lacks a current passing result, the verdict is
**Partially verified**, never Verified. The assessment also names failing,
missing, and previously passing suites dropped from the current gate set.

Never claim unqualified green from an aggregate test count, and never present
an inventory as proof that discovery was exhaustive: `state: "complete"` is a
worker-reported discovery claim, not independent proof. Missing structured
evidence stays **Verification unavailable**. Earlier passes become stale as soon
as the source revision moves, so record a fresh batch for the revision being
reported.

## External management versus scoped self-management

Inside a managed First Mate process, use the available `fm_*` tools for that
feature’s lifecycle. Do not route the feature’s own lifecycle through the
external CLI, bypass role guards, or skip a human checkpoint.

Outside that managed process, `herdr-first-mate` is the authenticated operator
CLI. Run `herdr-first-mate --help` for current syntax. These examples are
**READ-ONLY** external inspection; they do not authorize a mutation:

```sh
herdr-first-mate capabilities
herdr-first-mate get FEATURE_ID
herdr-first-mate agents FEATURE_ID
herdr-first-mate documents FEATURE_ID
```

The CLI also supports models, list/create, messages, assignments, Documents,
session pages, events, pause/resume/cancel, archive/unarchive, model settings,
feature links (`links`, `add-link`, `hide-link`, `restore-link`), and native
navigation. Archive changes visibility only; it does not stop or
steer work. Resume does not authorize the next stage. Mutations use stable
request IDs, and conflicts must be reloaded and reconciled rather than
overwritten. Link commands require a companion that advertises
`first-mate-links-v1`; older companions return upgrade guidance. Follow the
[control reference](control.md) for the same discovery,
receipt, and authorization boundaries outside First Mate.

Provider credentials remain in Pi/private companion configuration. The CLI and
API never make catalog presence proof that provider authentication works.

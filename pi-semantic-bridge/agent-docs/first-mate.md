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
| Coordinator | `fm_status`, `fm_delegate`, `fm_begin_stage`, `fm_recover`, `fm_resolve_gate`, `fm_steer`, `fm_retry`, `fm_complete_stage`, `fm_revise`, `fm_finish_feature`, `fm_read_document`, `fm_read_session` |
| Worker | `fm_status`, `fm_delegate`, `fm_retry`, `fm_wait_for_children`, `fm_outcome`, `fm_handoff`, `fm_acknowledge_handoff`, `fm_progress`, `fm_acknowledge_recovery`, `fm_request_human`, `fm_read_document`, `fm_read_session` |
| Advisor | `fm_status`, `fm_advice`, `fm_recovery_brief`, `fm_read_document`, `fm_read_session` |

Use `fm_delegate`, never unmanaged Pi subprocesses. Do not poll: service code
watches assignments and resumes the correct saved conversation. An agent exit or
summary is not a workflow verdict. Evidence and system outcomes are not human
authorization. Successor sessions must inspect and acknowledge the retained
handoff or recovery checkpoint before mutation. Current typed status is authoritative over old prose.

Use `fm_progress` at meaningful milestones with evidence and the next action.
Before a legitimate long build/wait, request a bounded lease; unchanged reports
are not progress. The service checks stale work hourly, nudges it, verifies a stop,
and continues only when preserved work and effect receipts establish a safe path.
Recovery advisors have read-only tools; ordinary roles keep their configured tools.
Missing receipts, uncertain external effects, human gates, and exhausted budgets
require direction rather than blind replay. `fm_recover` handles stopped/uncertain
execution; `fm_retry` handles a reported failure. Neither authorizes another stage.

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
and native navigation. Archive changes visibility only; it does not stop or
steer work. Resume does not authorize the next stage. Mutations use stable
request IDs, and conflicts must be reloaded and reconciled rather than
overwritten. Follow the [control reference](control.md) for the same discovery,
receipt, and authorization boundaries outside First Mate.

Provider credentials remain in Pi/private companion configuration. The CLI and
API never make catalog presence proof that provider authentication works.

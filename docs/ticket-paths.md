# Ticket paths

Active Work starts a ticket from a workflow template, then keeps its path with
that ticket. A template supplies a starting route. Revising one ticket does not
change another ticket or rewrite the template.

Newly connected Jira tickets start with **Ticket Journey**, which includes planning,
implementation and review loops, verification, human decisions, and review follow-up.
Other tasks can select it with `herdr-active-work create --kind task --title "Example
task" --workflow ticket-journey`. Existing templates remain available as starting points.

The ticket view puts the current step, next action, and responsible role first.
Use **Edit path** to add a step, change its title or checkpoint, or choose its
possible next steps. A return edge can represent review feedback or a failed
verification. Record why the route changed, then move through the chosen route.
Keep an explicit finish step reachable from every step.

A repeated step has another visit. Earlier summaries and linked evidence remain
available, so a second implementation or review pass does not erase the first.
You can remove an unused step, but current, visited, documented, or linked steps
must remain in the path. To bypass one, change the routes around it.

Human checkpoints keep their decision state. A rework route returns the ticket to
an earlier step with a reason; progressing past a decision requires its approval.
Moving the ticket records coordination state. It does not push code, merge a PR,
post comments, or perform other external work.

## Agent handoff

The installed `herdr-active-work` CLI exposes the same path used by the board.
It reads credentials from the existing private configuration. These examples use
synthetic item IDs; `REF` can also be a connected Jira key.

```sh
herdr-active-work path-show work_example
```

The JSON response includes `revision`, `path`, `loop`, and `editable_path`.
Save just `editable_path` as a JSON file. Its `stages` use `key`, `title`, `phase`,
`skill`, `checkpoint` (`none` or `human`), and an explicit `next` array of stage
keys. An empty `next` array ends a route. `phases` contains `{key,title}` entries.
Use the observed revision when saving the edited file:

```sh
herdr-active-work path-set work_example --file path.json \
  --expected-revision 4 --note "Add a focused fix and another review pass"
```

Use the new revision returned by every successful mutation. A conflict requires
reading the current ticket and reconciling the change, never retrying an old
payload with a newer revision.

```sh
herdr-active-work move work_example --to implement \
  --expected-revision 5 --note "Review found a missing empty state" \
  --next-action "Implement the empty state and rerun its checks"

herdr-active-work track work_example --expected-revision 6 \
  --owner implementer --status working \
  --next-action "Implement the empty state and rerun its checks" \
  --context "Review evidence is attached to the review step"
```

`track` saves the owner, status (`idle`, `working`, `waiting`, `blocked`, or
`done`), next action, reason, and resume context together. Use a responsible role
or session identity for ownership. Record the decision or evidence needed when
waiting, and the concrete next action that will resume work. The loop's status
describes the agent handoff; the ticket's lifecycle describes the work item.

On resuming a task, read its path and handoff, inspect evidence on the current
step, perform the authorized action, then save results and the next action.
Use `stage-set` and `attach-doc` for stage summaries and evidence links.
Revise the path before taking a new detour. Pi sessions started with the matching
Herdr package discover these commands automatically. After updating a registered
package, use `/reload`; sessions launched with explicit paths to an older version
need to be restarted or resumed with the updated package.
This supplies tracking context and tools; it does not schedule an agent or
automatically execute external actions.

## API and compatibility

`GET /api/v1/active-work/items/{id}` includes additive `path` and `loop` fields.
`item.stages` and `item.pipeline.stages` describe the effective ticket path;
the pipeline identity still identifies the originating template.

- `POST /api/v1/active-work/items/{id}/path` accepts `expected_revision`, `note`,
  `stages`, and optional `phases`.
- `POST /api/v1/active-work/items/{id}/transitions` accepts the target stage and
  expected revision. `note` records the reason and `next_action` saves the handoff
  atomically with the move.
- `PATCH /api/v1/active-work/items/{id}` accepts `loop` and `next_action` with
  `expected_revision`.

Path changes use the existing authenticated management API and publish the
existing `active_work.updated` event. An ingestion-only token cannot edit paths.
Older clients retain their existing fields. The Mac app loads this board from its
configured companion server, so the new board requires a server update rather
than a native app replacement. Install the matching CLI and Pi package as part
of that update.

Existing linear tickets retain compatible movement until their path is edited.
Tickets with branches, return routes, or per-ticket edits require explicit route
choices. This also applies to existing branched review templates. Passive
integration observations enrich these tickets with links and evidence but cannot
move them or overwrite their handoff. The driver uses the management API or CLI
to advance them after checking the observed results.
Take a consistent SQLite backup before upgrading. Path and visit data are durable
server state; preserve the database and private configuration during updates.

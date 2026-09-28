# First Mate autonomy and checkpoints

First Mate owns routine execution and recovery inside the human's authorized
scope. A failed tool, interrupted coordinator, or context handoff is an internal
repair task. A human checkpoint is a product or scope decision, an explicitly
requested review, unavailable credentials/resources, or an external effect whose
outcome cannot be established safely. These are different states.

## One direction, one continuing workflow

The coordinator records explicitly requested follow-up stages when it opens the
first stage. Those stages continue without asking the human to repeat permission.
An approved implementation can include builds, tests, local corrections, review,
and an explicitly authorized delivery. Completion of an internal milestone does
not create an additional approval gate.

Refining the goal immediately after opening an empty stage preserves that stage
and its follow-up grant when the same human turn still owns it. Revisions after
work has begun retain the existing writer-stop and scope-replacement checks.
Reported failures advertise the available repair action rather than incorrectly
requiring human recovery. Explicit human gates, pause, cancellation, and newer
human instructions remain authoritative.

## Recovery from retained state

- Coordinator turns have separate inactivity and total execution budgets. Model
  output (including streamed thinking) and distinct completed tools renew the
  inactivity budget. RPC responses, telemetry, empty deltas, and duplicate tool
  receipts do not. After the initial budget, the supervisor nudges the coordinator
  once to finish or delegate already authorized work instead of killing an active
  turn. The absolute ceiling still applies, even with continuous activity.
- A transient coordinator failure can retry twice with short backoff under the
  same inbox message. The controller first verifies the writer stopped, all
  managed requests have durable responses, and no arbitrary external mutation
  occurred. The next prompt includes completed operations and current state.
  Posted checkpoints, newer human direction, and unresolved effects prevent a
  duplicate continuation. Exhaustion produces one visible failure report.
  That report names the reason automatic continuation stopped and distinguishes
  workflow operations from other tool receipts. A completed receipt is not proof
  that an external command achieved its intended effect.
- The lead's relay and feature-creation receipts are tied to the original human
  turn and exact normalized action payload. Retrying with a different process or
  tool-call identifier returns the existing result for the same action. Completed
  action references remain in the retry context.
- Worker status is a bounded index of current assignments, verification results,
  and document references. It does not embed historical document bodies. Use
  `fm_status(assignment_id=...)`, `fm_read_document`, and `fm_read_session` for
  targeted detail. Truncated lists retain their counts.
- A successor completes required inspection and acknowledgement before the
  context watcher requests another handoff. A single bounded allowance after
  acknowledgement gives it room to act. Repeating acknowledgements cannot renew
  that allowance.
- The two-attempt recovery budget is per observed position. Actual source or
  completed-child changes can establish a new position; new wording, tokens,
  generations, and heartbeat messages cannot. Lifetime recovery counts remain
  available in assignment metadata.
- Four handoffs at an unchanged observed position trigger one focused automatic
  repair using the latest checkpoint. Another unchanged handoff escalates with
  retained evidence, instead of endlessly rotating or immediately requiring a
  human to say “go.”
- A malformed dispatch is isolated to its feature. Healthy features continue
  dispatch and supervision. Shared storage or database failures still defer new
  launches until durable state is available.

Conservative observation commands can pass the recovery fence. Arbitrary shell
scripts, builds, publishers, and remote actions are not assumed safe merely from
their names or exit status. Missing or failed external receipts still require
reconciliation. The controller never repeats an uncertain publication.

## One main response

A checkpoint or notice posted during a human turn is that turn's response. The
coordinator's closing text goes to the journal instead of posting another question.
Checkpoints that continue an authorized stage say so without suggesting another
approval. Native clients group legacy checkpoint/closing-reply pairs only when
their explicit feature and turn identities match. The additional response stays
available with its original text, feedback, and quote identity.

The Mac marks only the current visit's pending checkpoint as a decision. Recovery
has its own status, and unavailable monitoring does not claim that work is running.

## Delivery and limits

Install the matching companion wheel and Pi extension on each execution host.
The signed Mac update changes presentation and does not install server packages.
Existing conversations and explicit parked decisions are retained; installing an
update does not authorize new work or resume intentionally stopped assignments.

Release, authentication, source privacy, exact-revision verification, single-writer
ownership, and recovery archives remain enforced. Verification records from
different benchmark workspaces require explicit provenance. Historical failures
are not erased or silently excluded to make a result appear green.

Synthetic regressions cover duplicate checkpoint replies, same-turn goal repair,
coordinator retry and effect fencing, large-history status, context-pressure
acknowledgement, progress-based budgets, and cross-feature fault isolation.

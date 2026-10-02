# First Mate activity freshness and request budgets

First Mate, Second Mate and the clients read the same durable feature ledger.
The dashboard separates **Active now**, **Queued next**, and **Authorized next
stages**. Historical assignments do not occupy the slots for current workers.
Plans shown here are recorded workflow stages, not plans inferred from prose.

## Current and upcoming work

- Live workers include dispatching, running, waiting for children, handoff,
  acknowledgement and recovery states. All live and queued assignments remain
  visible, including workers retained through a later visit's membership.
- Pending coordinator messages are a separate projection, independent of the
  visible conversation page. Processing directions appear with current work;
  queued human directions precede routine background updates. The projection
  includes at most 100 messages with 1,200-character previews and explicit
  truncation indicators. An empty queue clears a previously displayed queue.
- Follow-up stages come from the current visit in the current plan revision.
  Superseded and cancelled plans cannot supply the upcoming stage list.
- Feature summaries count queued workers and queued/processing messages. A
  coordinator that has finished one reply is not presented as waiting for the
  human while the ledger still contains pending work.
- Mac and iOS use the same activity model in Overview and Workflow. Older
  companions remain compatible; unavailable queue details are identified and
  the clients can fall back to the messages those companions return.

## Reading and caching

Chat and the inspector have independent read loops. A mutation invalidates an
in-flight inspector response as well as its conditional version. A changed
plan, assignment or queue observed by Chat requests an inspector refresh.
Token telemetry alone does not restart expensive inspector reads.

Responses from an older plan or model revision cannot replace newer state.
Ordering within an inspector view uses the event cursor. Comparisons across
Chat and inspector reads also consider meaningful activity, so streaming
telemetry does not indefinitely reject a slower but otherwise current inspector
response.

The Mac inspector shows when a successful check completed. On failure it keeps
the last received content with a visible warning and Retry action. This is
eventual consistency, not an assertion that a disconnected client knows current
execution state. Normal inspector polling remains 10 seconds in the active
window, 20 seconds when non-key and 30 seconds in the background.

## Keeping status reads small

Scheduling and status inspection use direct assignment reads or journal-only
snapshots when Pi telemetry is unnecessary. This reduces time spent loading
historical events while holding the store lock.

Presentation responses avoid repeating large verification evidence in every
message and journal row. They retain provenance, explicit summary/truncation
metadata and references to full retained evidence. Current verification verdicts
and failures remain intact; historical verification can be summarized. The
durable ledger and authoritative workflow checks retain their complete evidence.
Projection versions change when the response shape changes, invalidating old
conditional responses after a companion upgrade.

## Timeout audit

Request budgets allow a loaded companion time to respond. A timeout is an
unknown request outcome. It does not cancel an agent and is not proof that the
machine is offline. Mutating requests are not automatically repeated after an
ambiguous timeout.

| Layer | Previous default | Current default |
| --- | ---: | ---: |
| First Mate peer request | 6 s | 60 s |
| Pi semantic command acknowledgement | 3 s | 30 s |
| Companion to native terminal RPC | 4 s | 30 s |
| Mac terminal send/run request | 5 s | 45 s |
| Native general API request | 15 s | 45 s |
| Native First Mate reads | 15 s | 90 s |
| Native health/network checks | 8 s | 30 s |
| Remote activity snapshot bootstrap | 8 s | 30 s |
| Control CLI request | 20 s | 60 s |
| First Mate CLI request | 20 s | 90 s |
| Native agent-run status request | 30 s | 45 s |

The peer budget can be set with `first_mate.peer_timeout_seconds` in the private
configuration, or `HERDR_FIRST_MATE_PEER_TIMEOUT_SECONDS`. The default is 60
seconds and values are bounded to 15 through 300 seconds. Non-finite or invalid
values use the default. The native read budgets accommodate the default peer
budget; increasing an operator override above the client budget does not also
change the client budget.

Python HTTP and native socket limits are socket inactivity limits, not strict
whole-operation wall-clock deadlines. Pi semantic commands additionally track a
monotonic response deadline. For native `agent.prompt` calls with an explicit
wait, the socket allows that validated wait plus five seconds. The control HTTP
client allows the same wait plus fifteen seconds. This preserves a requested
two-minute or five-minute completion wait rather than cutting it off at the
ordinary acknowledgement limit.

Peer connection failures still use the existing 30-second retry backoff.
Timeouts, HTTP errors, invalid responses and oversized responses remain
operation failures and do not mark the whole machine offline. Size limits,
authentication, redirect rejection and idempotency receipts remain enforced.

The audit also checked limits that serve other purposes:

- Managed worker startup allows 30 seconds. Worker execution allows 24 hours;
  coordinator inactivity allows 24 hours with a seven-day absolute ceiling.
- Managed tool spool requests survive restarts and wait for their durable
  response or cancellation. Their 100 ms poll interval is not a work timeout.
- SSE heartbeat/read intervals, local shutdown joins, cosmetic activity-model
  requests and bounded optional discovery probes are separate from execution.
- Existing long request budgets for First Mate writes, uploads, audio and
  release-related operations retain their established behavior.

## Remaining boundaries

The ledger can show only registered work. Child agents delegated through
`fm_delegate` retain assignment/session lineage. An arbitrary external agent
launched without registration does not automatically become a feature worker.
Agents should record their plan and delegation through the managed tools.

The scheduler still serializes reconciliation, so a slow operation can delay
other work. Current source isolates ordinary job failures to their feature and
reserves capacity for uncertain writers. A global storage failure still stops
new dispatch because durable ownership cannot be established. Older installed
companions may predate this existing isolation. Further latency work should
preserve writer checks and expose explicit degraded-state diagnostics.

The native terminal `/prompt` wait contract is distinct from the Pi semantic
`/pi/prompt` acknowledgement. The existing Mac `waitForIdle` option for the latter
is not implemented by that server route. It must not be used as evidence that a
Pi turn finished; resolving that separate contract requires an explicit wait
implementation or removing the misleading option.

App updates and companion updates are separate deliveries. The shared native
activity views need a new Mac/iOS build. Peer deadlines, compact projections and
queue fields need the matching companion package. Existing running installations
do not change merely because this source has been updated.

# First Mate command line

`herdr-first-mate` is installed with the companion wheel. It uses the same
private `--config` and `--machine` selection as `herdr-notes` and returns JSON.
It calls the authenticated First Mate API; it never simulates an agent response.
The upstream `herdr` terminal CLI remains independent. Managed First Mate agents
should use their scoped `fm_*` tools for their own workflow rather than routing
lifecycle operations through this external CLI. See the offline summary with
`herdr-docs read first-mate` and [agent awareness](../agent-awareness.md).

```sh
herdr-first-mate --config /path/to/config.toml --machine desktop capabilities
herdr-first-mate list
herdr-first-mate list --archived
herdr-first-mate list --all
herdr-first-mate create --title "Timer" --goal "Plan a daily timer" \
  --cwd /absolute/path/on/host --request-id timer-create-1
herdr-first-mate send FEATURE_ID --text-file instruction.txt --request-id timer-plan-1
herdr-first-mate get FEATURE_ID
herdr-first-mate agents FEATURE_ID
herdr-first-mate documents FEATURE_ID
herdr-first-mate messages FEATURE_ID
herdr-first-mate events FEATURE_ID --after 0
herdr-first-mate document DOCUMENT_ID
herdr-first-mate session NATIVE_SESSION_ID --limit 100
herdr-first-mate pause FEATURE_ID --request-id timer-pause-1 --expected-revision 1
herdr-first-mate resume FEATURE_ID --request-id timer-resume-1
herdr-first-mate archive FEATURE_ID --reason superseded --request-id timer-archive-1
herdr-first-mate unarchive FEATURE_ID --request-id timer-unarchive-1
herdr-first-mate open FEATURE_ID --graph
```

Use `--text-file -` to read a message from stdin. Explicit request IDs let an
agent retry an uncertain request without duplicating work. Keep the same ID and
body for that logical request. Commands never automatically retry mutations.
A conflict exits 4; other errors exit 2 and produce an error JSON object on
stderr. Successful output goes to stdout. Session pages include `next_before`;
pass that value to `session --before` to read earlier messages.

The default list contains active features. `list --archived` returns only archived
features and `list --all` returns both in deterministic update order. Archive is
not a lifecycle action: it retains status, workflow revision, visits, assignments,
documents, saved sessions, events, Active Work linkage and `work_item_id`. Running
work continues. Reasons are optional; supported values are `test/synthetic`,
`duplicate`, `no longer relevant`, `superseded`, and `other`.

`open` verifies the feature exists, then asks macOS to navigate the installed
Herdr app. It does not claim the app has finished navigating. Use `--tab agents`,
`--tab documents`, or `--graph`. `--print-url` returns the link without launching
anything. When the CLI uses loopback but the app has saved a Tailnet address,
provide `--app-server-url https://host.example.test:8461`. This must match an
existing saved connection in the Mac app. Links never carry tokens or prompts,
create connections, or execute work. Add an unrecognized machine in Settings
before opening its feature. Native navigation requires Mac build 28 or later;
API commands work with any server advertising `first-mate-v1`.

First Mate's host picker selects the saved connection for this workspace without
reordering other machines. In demo mode, **Connect to live work** returns to
saved connections (or pairing if none exist). Demo data is never migrated into
real server state.

The CLI can also `cancel` a feature. Pause/resume/cancel are explicit lifecycle
actions. Resume does not approve another stage. To choose the next stage, use
`send` with a human instruction. Agents should only send instructions within the
scope already authorized by their human. Session inspection is read-only; steer
workers through the feature's First Mate conversation.

Provider configuration belongs on the companion host. First Mate inherits the
provider credentials resolved from its private configuration, which may differ
from an interactive shell. Set `[machines.desktop.first_mate].model` to a Pi
provider/model identifier verified in that same environment. Natural-language
requests such as `Give me an architect review` use typed `model_profile:
architect` for architecture/design reviews, architect audits, and a second
opinion on an implementation. Set the independent
`[machines.desktop.first_mate].architect_model` and optional
`architect_thinking`. A model name or worker title alone does not override host
pins. Architect work has no assignment, worker, legacy-model, or Pi-default
fallback: an unset pin is shown as not configured and blocks only that work; it
is never re-routed through planning or execution. Before its task prompt, Pi must
report the exact provider-qualified model and configured effort through
`get_state`; mismatch blocks the assignment and retains requested-versus-actual
evidence. Acknowledgements state the requested role and pin; they claim actual
model evidence only after `model_selection.actual_*` is observed. Pi's advertised catalog alone does not
prove account access. Check a small real request before switching. Expired OAuth
refresh tokens require Pi's `/login` flow for that provider; never copy credentials
from another host.

## Feature model and thinking effort (companion 0.12.0b3+)

In Mac build 29 or later, click the model control above the First Mate message
field. Search the connected host's Pi model catalog, choose a model and thinking
effort, then Save. Each feature retains its own coordinator settings. Choose
Host default to inherit `first_mate.model`; Automatic effort retains Pi's saved
session/default behavior. Pi clamps requested effort to levels the model supports.
The model catalog reflects configured providers, not a successful billing or OAuth
check. Provider failures remain visible when the next turn runs.

```sh
herdr-first-mate models
herdr-first-mate get FEATURE_ID
herdr-first-mate set-model FEATURE_ID --model 'provider/model' --thinking high \
  --expected-settings-revision 0 --request-id feature-model-1
# Restore the host model and Pi's session/default effort:
herdr-first-mate set-model FEATURE_ID --model '' --thinking '' \
  --expected-settings-revision 1 --request-id feature-model-reset
# Change an established coordinator only after reading its exact current session:
herdr-first-mate set-model FEATURE_ID --model 'provider/model' --thinking high \
  --expected-settings-revision 2 --expected-session-id NATIVE_SESSION_ID \
  --confirm-session-model-change --request-id feature-model-confirmed
```

Read `feature.model_settings_revision` before updating. A stale revision returns
409 without overwriting another client's choice. Reuse the same request ID and
payload after an uncertain response. Each change adds one journal event. Settings
apply to new coordinator dispatches; existing dispatches, workers, advisors,
workflow revisions and human approvals remain unchanged. Saving does not start
a model turn. The native conversation continues across model changes.

Changing an established coordinator can reprocess conversation context, invalidate
prompt caches, and incur additional provider cost. Wait for a safe idle turn
boundary, pass the exact current `feature.native_session_id` with
`--expected-session-id`, and explicitly accept that risk with
`--confirm-session-model-change`. The CLI does not fetch or select a session and
never supplies confirmation automatically. Initial no-session requests omit both
fields unless you explicitly provide them.

The authenticated API adds `GET /api/v1/first-mate/models` and
`POST /api/v1/first-mate/features/:id/model-settings` with required `model`,
`thinking`, `expected_settings_revision`, and `request_id`, plus optional
`expected_session_id` and `confirm_session_model_change`. Capabilities include
`first-mate-model-settings-v1` and `first-mate-safe-model-settings-v1`. The feature
fields are additive. Older apps and CLI versions can continue using the server.
New apps retain chat on older servers and explain that model controls require a
companion update. The Mac updater does not install the companion package; update
that component separately.

## Feature links

A feature can retain pull requests and general HTTP(S) links. Recognizable
exact `github.com/<owner>/<repo>/pull/<number>` URLs found in managed First Mate
evidence are captured automatically; everything else is saved explicitly. Link
records never change workflow status, revision, authorization, or queued model
work, and the CLI never fetches, opens, or publishes a destination.

```sh
herdr-first-mate links FEATURE_ID
herdr-first-mate add-link FEATURE_ID \
  --url https://github.com/synthetic-owner/synthetic-repo/pull/12 \
  --title 'Synthetic review' --request-id feature-link-1
herdr-first-mate add-link FEATURE_ID \
  --url 'https://github.example.test/synthetic-team/synthetic-repo/pull/5/files' \
  --kind pull_request --request-id feature-link-2
herdr-first-mate add-link FEATURE_ID \
  --url 'http://share.example.test:8443/private/report?token=synthetic#summary' \
  --request-id feature-link-3
herdr-first-mate hide-link FEATURE_ID LINK_ID --request-id feature-hide-1
herdr-first-mate restore-link FEATURE_ID LINK_ID --request-id feature-restore-1
```

`links` returns the feature's complete retained link list, including hidden
rows, so a native client can offer Restore. `add-link` accepts the exact URL and
an optional title and classification (`pull_request` or `link`). Recognizable
github.com pull-request paths canonicalize to the pull-request root with owner
and repository casing folded, so a link to its files page, a link to the
conversation, and a casing variant deduplicate; a draft PR and a
ready-for-review PR are the same record. General links preserve their path,
query, and fragment, and bracketed IPv6 destinations are accepted with their
brackets intact. Credentials in a URL, non-HTTP(S) schemes, control characters,
and malformed hosts or ports are rejected with no side effect.

`hide-link` and `restore-link` address the exact feature and link IDs; a link ID
from another feature returns 404 and is never changed. Hiding is reversible and
survives automatic re-discovery or a repeated agent registration. Mutations use
stable request IDs: reuse the same ID and body after an uncertain response, and
reload on a conflict rather than overwriting another client's state. The CLI
checks `first-mate-links-v1` on `GET /capabilities` first. An older companion
returns `first_mate_links_unsupported` with upgrade guidance instead of
attempting an unknown route. Saving a link is not authorization to create a pull
request, open a share, or advance a stage.

The authenticated API routes are
`POST /api/v1/first-mate/features/:id/links` and
`POST /api/v1/first-mate/features/:id/links/:linkId/visibility`; the existing
feature snapshot carries the additive `links` array so older clients ignore it
safely. Companion and Mac updates remain independent; the Mac updater does not
install the companion package.

## Archive contract

Companions advertising `first-mate-archive-v1` accept `active`, `archived`, or
`all` through `GET /api/v1/first-mate/features?view=...`. Archive and unarchive
use the existing `POST /api/v1/first-mate/features/:id/actions` route with
`action`, `request_id`, and an optional archive `reason`. Mutations are
idempotent and do not wake, pause, cancel, resume, or otherwise steer agents.
The archive fields are additive, so older clients ignore them safely. New native
clients keep archive controls unavailable when the capability is absent.

First Mate records are scoped to the selected companion host. A list from one
Mac does not include another Mac's features. Select that host's connection using
`--base-url` and `--token-file`, or the appropriate private configuration profile.
`events --after` takes the integer event sequence cursor, not a timestamp. A
finished terminal pane is not an assignment verdict; inspect the recorded outcome
and documents before retrying work.

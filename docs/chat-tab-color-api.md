# Chat tab color API

Chat tab colors and their labels are local organization data. This document is
the read-only publication, snapshot, and discovery contract that lets agents
list and group chats by color or by label through the companion API without
copying that local data into any client's store.

The contract is additive. A companion advertising `chat-tab-colors-v1` supports
the publication endpoint and the extra snapshot/discovery fields described here.
Older servers continue to serve their existing routes: the new endpoint is
absent, control capabilities do not include `chat-tab-colors-v1`, discovery
rejects the new query parameters, and saved HUD commands are unchanged. Clients
must use the capability to distinguish "unsupported server" from "no chats
match"; a missing capability is never reported as an empty result. Updating the
Mac app does not install the companion server, CLI, or Pi package; those
components are updated separately.

Publication is implemented by the Mac app in this contract. Other clients keep
their own local assignments and are never represented as publishing or
inheriting this Mac's data.

## Local data stays local

- The Mac's `herdr.chatTabColors.v1` store remains the authority for its own
  assignments and labels. Publication writes only a server-side discovery copy;
  it never changes, synchronizes, or imports another client's local store.
- Assignments belong to one app installation. Every reported entry names the
  `clientId` whose assignment it is; a display name is descriptive only.
- Colors are six stable palette values: `lavender`, `iris`, `rose`, `clay`,
  `sage`, `slate`.
- Labels are the existing per-color label mapping, not chat titles. The
  publisher sends the effective label, including the palette default when the
  user has not renamed the color. Renaming a color is visible on every affected
  tab after the next successful publication.
- The requested workflow is read-only. Agents cannot write tab colors or
  labels through the companion API.

## Capability

`GET /api/v1/control/capabilities` (main API bearer required) returns:

```json
{
  "ok": true,
  "version": 1,
  "serverId": "srv_…",
  "capabilities": ["agent-control-v1", "discovery-v1", "chat-tab-colors-v1"],
  "chatTabColorStaleAfterSeconds": 60
}
```

`GET /api/v1` also lists `chat-tab-colors-v1` and the publication endpoint.

## Publish tab colors

```
POST /api/v1/control/chat-tab-colors/{clientId}
Authorization: Bearer <full API token>
```

The route requires the full API bearer even when the server otherwise permits
insecure loopback development. Active Work scoped credentials never authorize
it. In addition, every request carries a per-installation `publisherToken`:

- `clientId` is the stable installation identifier in the control `ui_<uuid>`
  form. It is not chosen from a display name, ordering, or recency.
- `publisherToken` is exactly 64 lowercase hexadecimal characters. The first
  successful publication for a `clientId` pins the SHA-256 hash of that token in
  a dedicated server-side table, independently of UI receiver registration and
  of its receiver secret. Later requests must present the identical token; a
  mismatch returns `401 publisher_unauthorized`. Tokens are never stored,
  echoed, or logged.

Request body:

```json
{
  "serverId": "srv_…",
  "publisherToken": "0123…64 hex…",
  "platform": "macos",
  "clientName": "Herdr Companion",
  "enabled": true,
  "revision": 12,
  "tabs": [
    {
      "workspaceId": "w1",
      "tabId": "w1:t1",
      "color": "sage",
      "label": "Synthetic Release Group"
    },
    {
      "workspaceId": "w2",
      "tabId": "w2:t4",
      "color": null,
      "label": null
    }
  ]
}
```

Field contract:

| Field | Rules |
| --- | --- |
| `serverId` | Must equal this server's `serverId`; anything else returns `409 stale_target`. This keeps identical raw tab IDs on two servers separate. |
| `publisherToken` | 64 lowercase hex characters, bound on first publication as described above. |
| `platform` | Generic lowercase platform identifier, `[a-z][a-z0-9_-]{0,31}` (for example `macos`). It describes the publisher; it is not an identity. |
| `clientName` | Trimmed single-line descriptive name, 1–120 characters, no control characters. Descriptive only. |
| `enabled` | Boolean. `false` withdraws exported values; `tabs` must then be empty. |
| `revision` | Integer from 1 through 2^53-1, strictly increasing for that client. |
| `tabs` | Array of at most 2048 entries; may be empty. Unknown fields are rejected. |

Tab entry contract:

| Field | Rules |
| --- | --- |
| `workspaceId` / `tabId` | Exact snapshot identities (`[A-Za-z0-9][A-Za-z0-9:._-]{0,255}`). A `(workspaceId, tabId)` pair may appear once. |
| `color` | One palette value or `null`. `null` with a `null` label is an explicit "known, not assigned" tab. |
| `label` | Required non-null when `color` is set, and `null` when `color` is `null`. Trimmed, at most 1024 Unicode code points and 4096 UTF-8 bytes, with no control, line-separator, or bidi-override characters. Valid Unicode is preserved. Because Swift counts extended grapheme clusters, limits are enforced in Python code points and UTF-8 bytes so a valid Mac label is never rejected by a differing count. |

Publication size is bounded: the canonical body is limited to 512 KiB, entries
to the count above, and stored publishers to a fixed server capacity. Exceeding
a bound returns an explicit error (`413 body_too_large` or
`publication_too_large`, `503 publisher_capacity`); data is never silently
truncated or dropped.

### Revision and heartbeat semantics

- A higher revision atomically replaces only that client's entries for this
  server. Other clients and other servers are untouched.
- An equal revision with a byte-identical canonical payload is an idempotent
  heartbeat. It refreshes `lastSeenAt` only; `updatedAt` keeps recording when
  the assignment last changed.
- An equal revision with a different payload returns `409 publication_conflict`.
- A lower revision returns `409 stale_publication_revision` and never clears or
  overwrites newer metadata.
- `enabled: false` clears the exported values but retains the credential and
  revision binding, so a delayed request with a lower revision cannot restore
  them.
- The Mac publishes promptly after a change and refreshes an unchanged
  publication about every 20 seconds. Timestamps are always server-generated.

Successful response:

```json
{
  "ok": true,
  "serverId": "srv_…",
  "publication": {
    "clientId": "ui_…",
    "platform": "macos",
    "clientName": "Herdr Companion",
    "enabled": true,
    "revision": 12,
    "tabCount": 2,
    "updatedAt": "2030-01-01T00:00:00Z",
    "lastSeenAt": "2030-01-01T00:00:00Z",
    "stale": false
  }
}
```

The response never contains the token or its hash, and never contains other
clients' data.

## Snapshot projection

`GET /api/v1/snapshot` (main API bearer) adds:

- `chatTabColorSources`: an array identifying every publisher of this server,
  in publication order.
- `chatTabColors` on each tab object once the companion knows about publishers;
  it is an empty array while nothing is published. Consumers must treat an
  absent `chatTabColors` array as empty, which keeps responses from a companion
  that never initialized agent-control state compatible.

```json
{
  "clientId": "ui_…",
  "platform": "macos",
  "clientName": "Herdr Companion",
  "enabled": true,
  "revision": 12,
  "updatedAt": "2030-01-01T00:00:00Z",
  "lastSeenAt": "2030-01-01T00:00:00Z",
  "stale": false
}
```

Each tab's `chatTabColors` has one entry per publisher, in the same order as
`chatTabColorSources`:

```json
{
  "clientId": "ui_…",
  "color": "sage",
  "label": "Synthetic Release Group",
  "status": "assigned",
  "updatedAt": "2030-01-01T00:00:00Z",
  "lastSeenAt": "2030-01-01T00:00:00Z",
  "stale": false
}
```

| `status` | Meaning |
| --- | --- |
| `assigned` | This publisher reports this tab with `color` and `label`. |
| `unassigned` | This publisher explicitly reports a known tab with no color. Never inferred from absence. |
| `unavailable` | The publisher is known but publishes no entry for this tab, or has withdrawn publication with `enabled: false`. Absence of a publisher is never reported as unassigned. |

Projection uses exact `(workspaceId, tabId)` identity. Every chat in a tab
inherits its tab's color metadata; the metadata is presentation data and is
never placed inside a typed target object.

Freshness: an entry is `stale: true` when the server has not received a
publication or heartbeat from that client for more than 60 seconds. Reads return
the last-known values, always marked with `stale`, so an offline client's
grouping survives without being presented as current. Timestamps are
server-generated ISO-8601 UTC values. When nothing has ever been published,
`chatTabColorSources` is `[]` and each known tab reports an empty
`chatTabColors` array.

Publications are private. Unauthenticated legacy-insecure snapshot responses
(the explicit loopback development mode with no configured API token) never
include `chatTabColors` or `chatTabColorSources`.

## Discovery

`GET /api/v1/discovery` accepts four additive parameters (absent parameters keep
existing behavior exactly):

| Parameter | Behavior |
| --- | --- |
| `color` | A palette value, or `none` for explicit unassignment only. `none` never matches a missing or `unavailable` entry. |
| `colorLabel` | Trimmed case-insensitive exact match of a published label. |
| `colorClientId` | Restricts matching to one publisher `clientId`. |
| `chatScope` | `terminal` excludes saved HUD chats and First Mate features from chat results; terminal pane, workspace, and tab records are unchanged. Absent or any other value is invalid. |

All supplied color predicates must match the **same** publisher entry, so
`--color sage --color-label Synthetic Release Group --color-client ui_…` never
combines one client's color with another client's label. A record without
publisher metadata does not match any color filter. `colorClientId` alone
selects the tabs that client reports, including explicit unassignment but not
`unavailable` entries.

Filtering happens before pagination, so a color query does not skip matches that
fall beyond the first page. `chatTabColors` entries are propagated to tab and
pane results and to exact `POST /api/v1/control/inspect` results; typed targets
are unchanged. Tab and pane search fields include the assigned colors and labels
as `tabColor` and `tabColorLabel` evidence, while saved-HUD catalog matching is
unchanged.

Coverage reports publisher availability and freshness:

```json
{
  "chatTabColors": {
    "searched": true,
    "staleAfterSeconds": 60,
    "publisherCount": 2,
    "currentPublisherCount": 1,
    "stalePublisherCount": 1,
    "disabledPublisherCount": 0,
    "available": true,
    "freshness": "current"
  }
}
```

`available` is true when at least one enabled publisher exists; `freshness` is
`current` when an enabled publisher is not stale, `stale` when only stale enabled
metadata remains, and `none` when no enabled publisher is available (including
zero publishers or all publishers withdrawn). `searched` is false with a reason
when the companion response does not expose publisher metadata.

### CLI mapping

The companion CLIs use these parameters for terminal-tab discovery:

```sh
herdr-control find chats --color sage --color-label "Synthetic Release Group"
herdr-control find chats --color none
herdr-control find chats --color-client ui_… --group-by label
herdr-hud-chats list --scope terminal --color iris
herdr-hud-chats search "planning" --scope terminal --color-label "Synthesé ✦ Planning"
```

`--group-by color|label` is a page-scoped projection of the returned rows, not a
complete group total. It retains typed targets, publisher provenance, stale
state, and the unassigned/unavailable distinction from each row. Saved HUD
commands keep their existing catalog behavior; `--scope terminal` adds terminal
chats without changing saved-history semantics.

## Read-only guarantee

- The discovery CLI surface is GET-only; it cannot assign or rename colors.
- The existing `chat.tab-color` agent action is disabled. Relay catalogs
  (`GET /api/v1/ui/clients…`) return it with `enabled: false` and a disabled
  reason, and both enqueue and claim reject it, including commands queued before
  the upgrade. The resource action route rejects it as well.
- Manual assignment, removal, and label editing in the app are unchanged.

## Errors

| Status | Code | Meaning |
| --- | --- | --- |
| 400 | `invalid_request` | A field, identifier, palette value, label, duplicate entry, or query parameter is invalid. |
| 401 | `unauthorized` | Missing or incorrect full API bearer. |
| 401 | `publisher_unauthorized` | A different `publisherToken` was presented for an already-bound `clientId`. |
| 409 | `stale_target` | `serverId` does not identify this server. |
| 409 | `stale_publication_revision` | Revision is older than the stored revision. |
| 409 | `publication_conflict` | Equal revision with a different payload. |
| 409 | `action_disabled` | `chat.tab-color` was requested through agent control. |
| 413 | `body_too_large`, `publication_too_large` | Body, entry, or label bound exceeded. |
| 503 | `publisher_capacity` | The bounded publisher registry is full; remove a stale publisher record deliberately rather than relying on silent eviction. |

Changing a bound `publisherToken` requires deliberately removing the stale
publisher record (or using a new installation identity); the endpoint never
rotates it implicitly.

## Verification

Regression coverage uses synthetic fixtures
(`tests/fixtures/chat-tab-colors-v1.json`), injected clocks, and two
installations publishing conflicting colors for the same tab against two
servers that reuse raw tab IDs. It covers authentication and spoofing, encoded
routes, restart persistence, revision ordering, disabled publication, explicit
unassignment, Unicode labels, filter-before-pagination, stale marking, relay
rejection, and the unauthenticated snapshot exclusion. Exact-source Verify and
the repository privacy gate remain required; this contract performs no
deployment.

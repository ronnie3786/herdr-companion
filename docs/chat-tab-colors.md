# Chat tab colors in companion discovery

Tab colors are personal organization data. The Mac app keeps each installation's
assignments and color labels in its own local store; the companion API can
carry a **read-only discovery copy** so agents can list and group chats by
color or by label through `herdr-control` and `herdr-hud-chats`.

Sharing is off by default. It never synchronizes assignments between clients,
never imports another client's values into a local store, and never lets an
agent change a color or label. The complete wire contract is in
[chat-tab-color-api.md](chat-tab-color-api.md).

## Enable sharing on the Mac

1. Open **Settings → Privacy → Tab colors**.
2. Turn on **Share tab colors with companions**. This is independent of
   **Allow agent control** and does not grant any action authority.
3. The same section shows this Mac's **Installation** ID (`ui_…`). That stable
   ID is how a snapshot, a CLI filter, or a group names the client whose
   assignments are being reported. It is not derived from a display name,
   ordering, or recency, and it is not a credential.
4. **Publication** reports whether every configured companion accepted the
   current values. Each host row explains waiting, publishing, shared,
   unsupported, or a bounded error state. Turn sharing off to withdraw the
   exported values; the local assignments and labels stay on this Mac.

While sharing is on, the Mac publishes each known tab's color and its
**effective label** (the custom name, or the palette default such as `Sage`
when no custom name is set) after a change, then refreshes an unchanged
publication about every 20 seconds. The local `herdr.chatTabColors.v1` store
remains the only authority. The companion stores one copy per publisher and
never sends it back as local state.

This publication is Mac-only in this release. The iPhone/iPad app keeps its own
local colors and is neither represented as a publisher nor given this Mac's
assignments.

## Required companion and CLI updates

Enabling the feature needs **all three** of the following, and the signed Mac
feed installs only the first:

- a Mac app that supports publication,
- a companion server advertising `chat-tab-colors-v1`, and
- the matching installed `herdr-control` and `herdr-hud-chats` CLIs.

The Mac updater does not install companion server packages or CLIs. Install the
updated wheel on each machine whose colors should be discoverable, then update
the CLIs that agents use. The CLIs detect a companion that does not advertise
`chat-tab-colors-v1` and report `chat_tab_colors_unsupported` instead of
returning an empty match. See [macOS releases](macos-releases.md) for the app
feed and the root
[README](../README.md#update-components-independently) for the separate server
procedure.

## Query from the CLIs

`herdr-control` adds color filters and grouping to `find chats`, `find tabs`,
and `find all`:

```sh
# Chats in one color, using the label and publisher installation explicitly.
herdr-control --machine desktop find chats \
  --color sage --color-label "Synthetic Release Group" --color-client ui_00000000-0000-4000-8000-000000000000

# Explicitly known-no-color tabs. `none` never matches missing metadata.
herdr-control --machine desktop find chats --color none

# Page-scoped grouping by the effective label or the palette color.
herdr-control --machine desktop find chats --color sage --group-by label
```

`herdr-hud-chats` keeps its existing saved-history catalog and adds an explicit
terminal scope:

```sh
herdr-hud-chats list
herdr-hud-chats list --scope terminal --color iris
herdr-hud-chats search "planning" --scope terminal --color-label "Synthesé ✦ Planning"
herdr-hud-chats --offset 50 list --scope terminal --group-by color
```

`--offset` is accepted before the subcommand, as historically, and after
`list` or `search`, matching `herdr-control find`.

`list`, `search`, and `show` default to the saved HUD history exactly as before;
color options are rejected there with a `--scope terminal` suggestion.
`--scope terminal` reads live terminal chats through discovery and does not
change saved-history behavior. On a companion without `chat-tab-colors-v1`,
both CLIs report the unsupported capability instead of returning a false empty
result.

### Filters

- `--color` accepts the six palette values `lavender`, `iris`, `rose`, `clay`,
  `sage`, and `slate`, or `none` for explicit no-color entries only.
- `--color-label` matches a published effective label exactly after trimming,
  case-insensitively. It matches labels, not chat or tab titles.
- `--color-client` restricts matching to one publisher installation. A
  `ui_…` value is normalized like the server normalizes it, so case does not
  matter.
- All supplied filters must match the **same** publisher entry, so one client's
  color is never combined with another client's label.

Filtering happens on the companion before pagination. A color query therefore
does not skip matches beyond the first page; use the returned cursor or
`nextOffset` as usual.

### Provenance and grouping

Every reported entry names its `clientId`, the installation whose assignment it
is. Snapshots list publishers separately in `chatTabColorSources`, and results
carry a `serverId` in their typed target. Two Macs that use the same display
name remain separate entries; select one with `--color-client` rather than by
name, order, or recency. Two companion hosts can reuse identical raw
workspace/tab/pane IDs without cross-contamination because entries are bound to
the server that stores them.

`--group-by color|label` is an additive, **page-scoped** projection of the rows
already returned:

- groups are separated by publisher `clientId`; publishers are never merged,
- one normalized label stays a single group within a publisher even when its
  tabs use several colors,
- each member keeps its typed target and the exact publisher entry that placed
  it in the group,
- `assigned`, `unassigned`, `unavailable`, and rows without tab metadata (for
  example saved HUD chats) stay distinct,
- group counts are page counts, not complete totals, and `groupingScope` is
  `page`.

Continue a paged command with `--cursor` and the same query settings; the
cursor validation includes the color and grouping options.

## Assigned, unassigned, and unavailable

| Reported state | Meaning | `--color none` |
| --- | --- | --- |
| `assigned` | This publisher reports this tab with a color and label. | no |
| `unassigned` | This publisher explicitly reports a known tab with no color. | yes |
| `unavailable` | The publisher is known but reports no entry for this tab, or has withdrawn publication. | no |

A tab that is absent from a publisher's copy is never invented as an explicit
"no color". Absence of a publisher (nothing ever shared from any client) is
different again: `chatTabColorSources` is empty and no tab matches a color
filter.

## Freshness and offline limits

- An entry is marked `stale: true` when the companion has not received a
  publication or heartbeat for more than 60 seconds. Timestamps are
  server-generated.
- Reads return last-known values, always marked with `stale`, so an offline
  client's groups remain visible without being presented as current. Coverage
  reports `freshness: current`, `stale`, or `none`, plus publisher counts.
- Export only happens after a topology read confirmed for the current endpoint
  **and** the authenticated companion identity. If a replacement companion
  answers at the same URL and token with a new `serverId`, the Mac treats the
  cached workspace identities as belonging to the previous server and waits for
  a fresh topology read before publishing, so the old tab IDs and personal
  labels are never sent to the replacement.
- Duplicate machine aliases that reach one companion are compared by their local
  assignments. Conflicting aliases pause publication for that companion, and
  the alias binding is persisted, so relaunching with one alias offline still
  blocks publication instead of treating the reachable alias as authority.
- A pane without a valid tab identity is not a tab. The publisher omits it
  rather than emitting an entry the companion would reject wholesale, so it is
  never reported as explicitly unassigned either.
- The server keeps a per-`clientId` credential and revision binding until it is
  deliberately removed. A delayed or replayed older revision is rejected, so it
  cannot clear or restore newer metadata.
- An offline Mac cannot update or withdraw its exported values. Turning sharing
  off or removing colors while disconnected takes effect after the next
  successful authenticated publication; until then the companion keeps serving
  the last-known copy marked stale. Only the publisher can clear its own copy —
  server-side reads never modify it, and an operator cannot clear it through the
  discovery surface. A bound publisher credential and revision are likewise not
  rotated implicitly: changing them needs a deliberately removed publisher
  record or a new installation identity.

## Read-only guarantee

- Discovery is GET-only. Neither CLI can assign a color or rename a label.
- The existing `chat.tab-color` agent action is disabled. Relay catalogs return
  it with `enabled: false` and a read-only reason, and both command admission
  and claim reject it, including commands queued before the upgrade. A CLI that
  ignores the catalog receives `action_disabled`.
- Manual color assignment, removal, and label editing in the app are unchanged.

## Verification

The Python contract suite uses synthetic fixtures
(`tests/fixtures/chat-tab-colors-v1.json`), injected clocks, and two
installations publishing for the same tab. A separate synthetic loopback suite
(`tests/test_chat_tab_color_integration.py`) publishes that fixture to real
snapshot/discovery routes and invokes both CLI entry points, covering matching
membership after assignment, rename, reset, removal, and a new sibling pane;
conflicting publishers; repeated raw IDs on separate servers;
filter-before-pagination; stale metadata; publication withdrawal; and the
refusal of an agent color mutation. Native Mac suites cover the local store and
publisher, including two independent UserDefaults suites that verify neither
publication nor reading imports another client's values.

Those are synthetic transport and fixture checks. Installed-app behavior —
Settings opt-in, the displayed installation ID, and real color editing — is
verified with the synthetic walkthrough in the
[Mac manual test checklist](../herdr-harness-mac/MANUAL_TEST_CHECKLIST.md#tab-colors-and-sidebar-filtering).
At the final gate, a single validation owner runs the complete exact-SHA Verify
workflow — required Python, web/Pi, native Mac, privacy, and standalone-wheel
checks, retaining the existing conditional iOS policy — plus the manual
synthetic walkthrough. Required CI is authoritative, so the local gate does not
duplicate its entire matrix. This documentation describes source behavior only;
it does not install or deploy a server, CLI, or app.

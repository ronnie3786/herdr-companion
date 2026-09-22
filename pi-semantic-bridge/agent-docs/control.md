# Companion discovery and control

Use the installed `herdr-control` CLI for capability-driven discovery, exact
navigation, and typed resource or Mac UI actions. It calls an authenticated
companion; it does not simulate clicks, use AppleScript, or replace the upstream
`herdr` terminal CLI. See the [agent overview](overview.md) for component
boundaries, the [API map](api.md) for full routes, and the
[First Mate reference](first-mate.md) for that workflow’s scoped tools.

Start with live help because global and leaf option placement differs:

```sh
herdr-control --help
herdr-control machines
herdr-control find chats --help
herdr-control actions list
herdr-control --control-machine desktop ui clients
herdr-control --control-machine desktop ui state
```

## Safe workflow

1. Select the **data machine** (`--machine`, or `--all-machines` for supported
   searches) separately from the **control relay machine** (`--control-machine`)
   and receiving Mac installation (`--client`). Names, roles, order, and labels
   do not prove identity.
2. Search with `find chats|workspaces|tabs|all`. Review coverage, freshness,
   errors, pagination, and every candidate; never pick the first ambiguous match.
3. Save the chosen typed target JSON and revalidate it with
   `inspect --ref-file target.json`.
4. Inspect `actions list` and `actions describe ACTION`, or `ui actions`, for the
   current typed schema and enabled state.
5. Invoke only an already-authorized action. Supply stable request IDs for
   mutations and retain the exact payload.
6. Read the receipt. `accepted`, `running`, pending, timeout, and
   `outcome_unknown` are not success. After uncertainty, inspect/reconcile and
   retry only the same payload with the same request ID.

Representative commands:

```sh
herdr-control find chats --all-machines --query "synthetic retry"
herdr-control --machine desktop inspect --ref-file target.json
herdr-control --machine desktop --control-machine desktop ui open \
  --ref-file target.json --view chat --wait 30
herdr-control --machine desktop actions describe pane.rename
herdr-control --machine desktop actions receipt REQUEST_ID
herdr-control --control-machine desktop ui receipt REQUEST_ID
```

Resource creation is split from presentation. `workspace create`, `tab create`,
and `chat create` return resource receipts; `--open` also requests separate UI
navigation. If creation succeeds and opening fails, retry navigation rather than
creating a duplicate.

## Limits and authority

The live catalogs are authoritative. Coverage is not complete app-wide parity;
unsupported actions fail and must not be replaced with terminal keystrokes or
arbitrary UI scripting. Saved HUD history and First Mate have dedicated CLIs.
Tab colors are read-only discovery data for agents. Control requires configured
credentials and, for Mac UI actions, the user’s one-time **Allow agent control**
setting. Discovery grants no authority, bypasses no busy/modal guard or human
checkpoint, and never justifies printing or passing a token.

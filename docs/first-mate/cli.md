# First Mate command line

`herdr-first-mate` is installed with the companion wheel. It uses the same
private `--config` and `--machine` selection as `herdr-notes` and returns JSON.
It calls the authenticated First Mate API; it never simulates an agent response.
The upstream `herdr` terminal CLI remains independent.

```sh
herdr-first-mate --config /path/to/config.toml --machine desktop capabilities
herdr-first-mate list
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
herdr-first-mate open FEATURE_ID --graph
```

Use `--text-file -` to read a message from stdin. Explicit request IDs let an
agent retry an uncertain request without duplicating work. Keep the same ID and
body for that logical request. Commands never automatically retry mutations.
A conflict exits 4; other errors exit 2 and produce an error JSON object on
stderr. Successful output goes to stdout. Session pages include `next_before`;
pass that value to `session --before` to read earlier messages.

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
provider/model identifier verified in that same environment. Pi's advertised
catalog alone does not prove account access. Check a small real request before
switching. Expired OAuth refresh tokens require Pi's `/login` flow for that
provider; never copy credentials from another host.

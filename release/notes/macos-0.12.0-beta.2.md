# First Mate live controls

- Demo workspaces now show **Connect to live work** directly in the First Mate sidebar. Exiting demo restores saved machines instead of always sending you through pairing.
- A companion host picker lets First Mate target the intended saved machine.
- The companion package adds `herdr-first-mate`: JSON commands for features, messages, agents, documents, saved sessions, events, and pause/resume/cancel.
- `herdr-first-mate open FEATURE_ID --graph` opens the native workspace on a saved server. Navigation links cannot send prompts or execute work.

The Mac app and companion package are separate updates. Install companion 0.12.0b2 for the CLI entry point. Existing first-mate-v1 servers remain compatible with the app. The workflow graph remains the initial stage-card view; this release does not replace it with the HTML prototype's branching canvas.

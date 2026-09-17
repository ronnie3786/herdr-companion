# Companion 0.16.1 Preview 1

## Lightweight Pi conversation context

- Add the installed, read-only `herdr-session-context` CLI. `herdr-session-context get --workspace-id <workspace-id> --session-id <session-id>` prints the bounded visible user/assistant context projected by Herdr; `--json` includes its metadata.
- Discover the matching companion through the terminal's owner-private, socket-namespaced connection and authenticate with the configured main bearer token. The CLI rejects remote plaintext HTTP, credential-bearing origins, and redirects, and redacts credentials from output and errors.
- Include Pi guidance that treats fetched conversation context as prior user data, never as higher-priority instructions. The projection excludes system data, thinking, tool calls and results, provider metadata, signatures, and raw session envelopes.
- Advertise and consume the authenticated `pi-session-context-v1` API used by matching Mac conversation-reference chips. Context remains addressable by its real Herdr workspace ID and current Pi session ID while retained in the bounded semantic journal.

## Separate server installation required

This is a companion **server and CLI package**, not a Mac installer. The Mac signed updater does not install this wheel, switch or restart services, or update configured Pi packages. Conversation references require the matching Mac **0.16.1-beta.1 build 40**, companion **0.16.1b1**, and packaged Pi extensions on the same machine.

Follow the documented server update procedure: install the released wheel in a new versioned environment, verify its packaged resources and private configuration, then explicitly switch only the intended companion service. Preserve the existing state directory, semantic journal, private TOML, credentials, terminal socket configuration, and rollback environment. No live server cutover is implied by publishing either release.

## Verify after updating

From a Herdr-managed Pi session, run `herdr-session-context get` with a known workspace/session pair and confirm it prints only visible user and assistant context. Repeat with `--json` to inspect metadata. A missing or mismatched pair must fail clearly; requests without the configured main API token, with an unrelated scoped token, through a redirect, or to a remote plaintext HTTP origin must be rejected without exposing credentials.

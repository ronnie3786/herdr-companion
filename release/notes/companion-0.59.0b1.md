# Herdr Companion server 0.59.0b1

Adds revision-bound PR review walkthroughs and question answers for the native
Mac review buddy, with authenticated context and guide endpoints. Each request
retains a context snapshot and supplies a pinned copy of committed source to the
restricted read-only agent. Follow-ups retrieve current report context; retries
reuse the original snapshot.

Saved Markdown and HTML reports provide bounded original excerpts, exact-path
matching, available reviewer labels, revision freshness, and dismissal context.
Unknown provenance stays unknown. The buddy records its assessment separately
from the original report and cannot claim a test reproduction from inspection.

An additive captioned speech endpoint uses the existing private response-audio
Kokoro configuration. It returns measured audio duration, word timestamps, exact
script/recording hashes, and validated phrase cues for each selected voice.
Ordinary response audio and existing `pr-review-v1` clients remain compatible.

Install the wheel in a new versioned runtime. Preserve the private TOML,
credentials, review records, and state; validate configuration and Fleet paths,
back up state consistently, then switch the companion service, installed CLIs,
Pi package, and enabled workers together. Verify authenticated health and saved
state after restart. Retain the prior runtime for rollback. The signed Mac app
feed does not install this server package.

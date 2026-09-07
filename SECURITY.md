# Security

Herdr can control terminal sessions and access files available to its server user.
Keep it authenticated. Bind to loopback by default and use trusted HTTPS for remote
access. Select machine and Fleet catalog configuration explicitly. Optional model
and speech providers receive the content needed for their enabled features.

Treat private configuration and app/server state as sensitive. The initializer
creates owner-only configuration and never prints its token. Use Keychain, private
token files, or secret-manager environment injection as appropriate. Never attach
unredacted configuration, transcripts, databases, or diagnostic bundles to issues.

Use GitHub's private vulnerability reporting for this repository when available.
Do not put credentials or exploitable private details in public issues. If a
credential was exposed, revoke or rotate it first; deleting files or rewriting
repository history does not invalidate old copies.

Source checks supplement review and dedicated secret scanning. They do not certify
arbitrary binary artifacts or personal configuration as safe to publish.

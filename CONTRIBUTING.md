# Contributing

Use Python 3.11+, Node.js 22.19+, and Xcode 26.2+ for native changes. Follow the
README's installation and verification commands. Use temporary state and
synthetic fixtures; do not test against a live cluster.

Keep native apps, API contracts, and web client compatible. Update affected
client fixtures/tests when changing schemas. Preserve authentication, token scopes,
path containment, response bounds, and handling of ambiguous agent submissions.

Machine settings belong in your private TOML. Never commit filled-in configuration,
credentials, personal machine/domain names, captured conversations, real work items,
device registrations, or private builds. Run the public source check and a dedicated
secret scanner before proposing changes. Retain third-party notices.

Describe resulting behavior and relevant verification in pull requests. Use
screenshots from synthetic demo mode for visible UI changes.

Maintain the README’s plain-English feature list when adding, removing, or changing
user-facing capabilities. State which client supports the feature and whether it
needs an optional service. Keep per-version changes in release notes.

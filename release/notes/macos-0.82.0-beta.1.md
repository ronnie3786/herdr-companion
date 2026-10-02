# macOS 0.82.0-beta.1

## PR review progress

PR Review now shows viewed and remaining file counts at the top of the file list,
for example **3 of 10 viewed · 7 unviewed**. Each viewed file has a **Viewed**
badge. When **Hide viewed** hides every file, the list shows **All files viewed**.

[Issue #151](https://github.com/ronnie3786/herdr-companion/issues/151) ·
[PR #157](https://github.com/ronnie3786/herdr-companion/pull/157)

## Companion compatibility

This release updates the Mac app only. Review progress requires the existing
`pr-review-v1` capability; no companion update is needed beyond that. The
companion server, CLI, and Pi package are published separately and are not
installed by the Mac updater.

## Install and verify

With preview updates enabled, use **Settings → Updates → Check for Updates…** and
install **0.82.0-beta.1** (build **131**). Open a PR review and mark files as
viewed: check that the counts update and each viewed file shows its badge. Mark
all files viewed, enable **Hide viewed**, and confirm **All files viewed** appears.

# Companion 0.79.0-beta.1

Adds saved First Mate projects and authenticated folder browsing for Mac 0.94.0-beta.1. Projects belong to the companion machine, keep stable IDs, and support revision-checked edits, archiving, and restoration. Starting a session snapshots the selected project and records the exact opening direction once, with persisted request receipts for safe retries.

The additive capabilities are `first-mate-projects-v1` and `directory-browser-v1`. Existing manual session creation, web clients, and iOS clients remain compatible. First Mate schema migration 19 adds project records and nullable session metadata while preserving existing sessions and migrations.

Install the wheel in a new versioned runtime using the server update procedure in `herdr_harness/README.md`. Preserve private configuration and back up state before upgrading. Update matching CLI/Pi components and restart affected services only after active work is safe. The Mac updater does not install this package or restart companions.

After installation, pair the updated Mac app with the companion, open **First Mate → Projects**, and create a project using the remote folder browser. Start a session and confirm its overview retains the chosen project name and folder.

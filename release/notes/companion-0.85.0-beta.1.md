# Companion 0.85.0-beta.1

First Mate can now retain a searchable, immutable completion record and clean up explicitly selected session-owned disposable resources after completion.

- Adds `first-mate-archive-review-v1` and `first-mate-archive-cleanup-v1`. Read-only previews return resource eligibility, logical size estimates and a token bound to the current session and resource state. Cleanup requires the reviewed revision, token, resource IDs and retention choices together.
- Ordinary archive requests from older Mac, iOS and web clients remain visibility-only and retain files. Active work continues. Project-only archive keeps its source folder and sessions.
- The full original request, conversation, documents, recorded links, outcomes, usage and historical evidence are cataloged before deletion. Optional compaction moves live chat/document copies to that catalog. Search, export, durable progress logs and safe retry remain available.
- Only resources created and registered by First Mate are candidates. Cleanup rechecks ownership, archive generation, stopped writers and Git state. Modified or unintegrated worktrees, source projects, backups, published builds, shared resources and unknown files are retained. Legacy resources without ownership receipts are retained.
- Adds the host-local `fm_allocate_resource` tool for disposable build/cache directories. Resource allocation does not grant access to another machine or arbitrary filesystem paths.

Install this companion wheel separately on each server; the Mac updater installs only the app. Keep the private configuration and state, take a consistent state backup, and switch services at a safe boundary while preserving detached sessions. Keep the previous runtime for rollback. Existing clients remain compatible; the native review is included in Mac 0.103.0-beta.1.

After installation, verify authenticated `GET /api/v1/first-mate/capabilities` includes both archive capabilities and `GET /api/v1/first-mate/history` succeeds. Open a completed session in the standalone First Mate window and choose **Archive session…** to review cleanup before confirming.

import Foundation

enum PRReviewDemo {
    static let reviewID = "prr_demo42"
    static let secondReviewID = "prr_demo43"
    static let archivedReviewID = "prr_archived"

    static func snapshot() -> PRReviewSnapshot {
        var value: PRReviewSnapshot = decode(defaultSnapshot)
        value.files.append(contentsOf: deletedSnapshotFiles)
        // Keep the review summary consistent with its synthetic file list.
        value.review.changedFiles = value.files.count
        value.review.additions = value.files.reduce(0) { $0 + $1.additions }
        value.review.deletions = value.files.reduce(0) { $0 + $1.deletions }
        return value
    }

    /// Review-aware lookup used by the demo store and popped-out windows:
    /// each active synthetic review keeps its own files, runs, and documents.
    static func snapshot(for reviewID: String) -> PRReviewSnapshot {
        reviewID == secondReviewID ? decode(secondSnapshot) : snapshot()
    }

    static func reviews() -> [PRReviewSummary] {
        [snapshot().review, snapshot(for: secondReviewID).review]
    }

    static func archivedReviews() -> [PRReviewSummary] { var value = snapshot().review; value.id = archivedReviewID; value.title = "Archive seed labels"; value.archivedAt = "2026-01-14T14:30:00Z"; return [value] }

    static func diff() -> PRReviewDiff {
        var value: PRReviewDiff = decode(defaultDiff)
        value.files.append(contentsOf: deletedDiffFiles)
        return value
    }

    static func diff(for reviewID: String) -> PRReviewDiff {
        reviewID == secondReviewID ? decode(secondDiff) : diff()
    }

    private static let defaultSnapshot = """
    {"ok":true,"review":{"id":"prr_demo42","url":"https://dev.example.test/example-owner/garden-planner/pull/42","owner":"example-owner","repo":"garden-planner","number":42,"title":"Add seed catalog sync","author":"sam","base_ref":"main","head_ref":"seed-sync","base_sha":"base","head_sha":"head","github_state":"OPEN","is_draft":false,"status":"ready","ranking_state":"idle","additions":84,"deletions":23,"changed_files":10,"revision":1,"running_runs":1,"document_count":4,"created_at":"2026-01-15T14:30:00Z","updated_at":"2026-01-15T14:30:00Z"},"files":[{"path":"Sources/Catalog/SeedCatalog.swift","status":"modified","additions":12,"deletions":2,"impact":"high","guided_order":1,"viewed":false},{"path":"Sources/Catalog/SyncClient.swift","status":"added","additions":20,"deletions":0,"impact":"high","guided_order":2,"viewed":false},{"path":"Sources/Models/Seed.swift","status":"modified","additions":8,"deletions":1,"impact":"medium","guided_order":3,"viewed":false},{"path":"Sources/Storage/SeedStore.swift","status":"modified","additions":11,"deletions":3,"impact":"medium","guided_order":4,"viewed":true},{"path":"Tests/CatalogTests.swift","status":"modified","additions":16,"deletions":2,"impact":"low","guided_order":5,"viewed":false},{"path":"Tests/SyncClientTests.swift","status":"added","additions":14,"deletions":0,"impact":"low","guided_order":6,"viewed":false},{"path":"README.md","status":"modified","additions":3,"deletions":4,"viewed":false}],"skills":[{"id":"comprehensive-pr-review","title":"Comprehensive review","kind":"review","runner":"agent","prompt_template":"","command_template":"","outputs":[],"description":"","builtin":true,"enabled":true,"state":"ran","run_count":1,"running":false},{"id":"seed-sync-check","title":"Seed sync checks","kind":"custom","runner":"agent","prompt_template":"/seed-sync-check {number}","command_template":"","outputs":["*.md"],"description":"Custom catalog review","builtin":false,"enabled":true,"state":"not_run","run_count":0,"running":false}],"runs":[{"id":"prun_finished","review_id":"prr_demo42","skill_id":"comprehensive-pr-review","skill_title":"Comprehensive review","state":"finished"},{"id":"prun_running","review_id":"prr_demo42","skill_id":"seed-sync-check","skill_title":"Seed sync checks","state":"running"},{"id":"prun_ended","review_id":"prr_demo42","skill_id":"ios-review-remote-pr","skill_title":"iOS review","state":"ended"}],"documents":[{"id":"prdoc_findings","review_id":"prr_demo42","kind":"markdown","title":"Review findings","media_type":"text/markdown","filename":"findings.md","byte_size":120,"content_hash":"a","origin":"skill","downloadable":true},{"id":"prdoc_report","review_id":"prr_demo42","kind":"html","title":"Catalog report","media_type":"text/html","filename":"report.html","byte_size":120,"content_hash":"b","origin":"skill","downloadable":true},{"id":"prdoc_audio","review_id":"prr_demo42","kind":"audio","title":"Audio summary","media_type":"audio/mpeg","filename":"summary.mp3","byte_size":120,"content_hash":"c","origin":"skill","downloadable":true},{"id":"prdoc_video","review_id":"prr_demo42","kind":"video","title":"Video walkthrough","media_type":"video/mp4","filename":"walkthrough.mp4","url":"https://dev.example.test/video","byte_size":0,"content_hash":"d","origin":"skill","downloadable":false}],"events":[{"id":"prev_prepared","sequence":1,"review_id":"prr_demo42","type":"review.prepared","summary":"Review prepared","payload":{},"created_at":"2026-01-15T14:30:00Z"}]}
    """

    private static let secondSnapshot = """
    {"ok":true,"review":{"id":"prr_demo43","url":"https://dev.example.test/example-owner/garden-planner/pull/43","owner":"example-owner","repo":"garden-planner","number":43,"title":"Tune watering reminders","author":"kim","base_ref":"main","head_ref":"watering","base_sha":"base-43","head_sha":"head-43","github_state":"OPEN","is_draft":false,"status":"ready","ranking_state":"idle","additions":21,"deletions":9,"changed_files":2,"revision":1,"running_runs":0,"document_count":1,"created_at":"2026-01-16T09:00:00Z","updated_at":"2026-01-16T09:00:00Z"},"files":[{"path":"Sources/Watering/ReminderSchedule.swift","status":"modified","additions":14,"deletions":9,"impact":"high","guided_order":1,"viewed":false},{"path":"Tests/WateringTests.swift","status":"added","additions":7,"deletions":0,"impact":"low","guided_order":2,"viewed":false}],"skills":[{"id":"watering-review","title":"Watering review","kind":"review","runner":"agent","prompt_template":"","command_template":"","outputs":[],"description":"","builtin":true,"enabled":true,"state":"not_run","run_count":0,"running":false}],"runs":[],"documents":[{"id":"prdoc_watering","review_id":"prr_demo43","kind":"markdown","title":"Watering notes","media_type":"text/markdown","filename":"watering.md","byte_size":80,"content_hash":"e","origin":"skill","downloadable":true}],"events":[{"id":"prev_watering","sequence":1,"review_id":"prr_demo43","type":"review.prepared","summary":"Review prepared","payload":{},"created_at":"2026-01-16T09:00:00Z"}]}
    """

    private static let defaultDiff = """
    {"ok":true,"review_id":"prr_demo42","base_sha":"base","head_sha":"head","truncated":false,"files":[{"path":"Sources/Catalog/SeedCatalog.swift","old_path":"","status":"modified","additions":3,"deletions":1,"binary":false,"truncated":false,"hunks":[{"old_start":1,"old_lines":1,"new_start":1,"new_lines":2,"header":"@@","lines":[{"kind":"context","old_number":1,"new_number":1,"text":"import Foundation"},{"kind":"add","old_number":null,"new_number":2,"text":"struct SeedCatalog {}"}]},{"old_start":8,"old_lines":1,"new_start":9,"new_lines":1,"header":"@@","lines":[{"kind":"del","old_number":8,"new_number":null,"text":"old"}]},{"old_start":12,"old_lines":1,"new_start":12,"new_lines":1,"header":"@@","lines":[{"kind":"context","old_number":12,"new_number":12,"text":"end"}]}]}]}
    """

    private static let secondDiff = """
    {"ok":true,"review_id":"prr_demo43","base_sha":"base-43","head_sha":"head-43","truncated":false,"files":[{"path":"Sources/Watering/ReminderSchedule.swift","old_path":"","status":"modified","additions":2,"deletions":1,"binary":false,"truncated":false,"hunks":[{"old_start":1,"old_lines":1,"new_start":1,"new_lines":2,"header":"@@","lines":[{"kind":"context","old_number":1,"new_number":1,"text":"import Foundation"},{"kind":"add","old_number":null,"new_number":2,"text":"struct ReminderSchedule {}"}]},{"old_start":9,"old_lines":1,"new_start":10,"new_lines":1,"header":"@@","lines":[{"kind":"del","old_number":9,"new_number":null,"text":"let staleInterval = 60"}]}]}]}
    """

    /// Synthetic deleted files appended after every existing first-review file,
    /// so earlier indexes and identities stay stable. They add one deleted
    /// source file, one deleted prose file, and a long-path deleted source file
    /// with the same removal hunks the UI discloses on demand.
    private static var deletedSnapshotFiles: [PRReviewFile] {
        decode("""
    [
    {"path":"Sources/Legacy/SeedCatalogMigration.swift","status":"deleted","additions":0,"deletions":5,"impact":"medium","impact_reason":"Removed the legacy migration path; confirm no remaining callers.","guided_order":8,"guided_reason":"Check removed legacy migration call sites last.","viewed":false},
    {"path":"Docs/Guides/seed-catalog-rollout.md","status":"deleted","additions":0,"deletions":4,"impact":"low","impact_reason":"Archived rollout notes; the current guide carries them forward.","guided_order":9,"guided_reason":"Read only if the rollout history still matters.","viewed":false},
    {"path":"Sources/Legacy/Compatibility/SeedCatalogLegacyCompatibilityShimsAndMigrationHelpers.swift","status":"deleted","additions":0,"deletions":2,"guided_order":10,"guided_reason":"Remove the compatibility shims last.","viewed":false}
    ]
    """)
    }

    /// Removal hunks for `deletedSnapshotFiles`, appended after the existing
    /// diff files. Old-side numbers are genuine so the disclosure renders the
    /// original line numbers, and the review summary above stays truthful.
    private static var deletedDiffFiles: [PRReviewDiffFile] {
        decode("""
    [
    {"path":"Sources/Legacy/SeedCatalogMigration.swift","old_path":"","status":"deleted","additions":0,"deletions":5,"binary":false,"truncated":false,"hunks":[{"old_start":1,"old_lines":5,"new_start":0,"new_lines":0,"header":"@@","lines":[{"kind":"del","old_number":1,"new_number":null,"text":"import Foundation"},{"kind":"del","old_number":2,"new_number":null,"text":""},{"kind":"del","old_number":3,"new_number":null,"text":"struct SeedCatalogMigration {"},{"kind":"del","old_number":4,"new_number":null,"text":"    let legacyCatalog: [String]"},{"kind":"del","old_number":5,"new_number":null,"text":"}"}]}]},
    {"path":"Docs/Guides/seed-catalog-rollout.md","old_path":"","status":"deleted","additions":0,"deletions":4,"binary":false,"truncated":false,"hunks":[{"old_start":1,"old_lines":4,"new_start":0,"new_lines":0,"header":"@@","lines":[{"kind":"del","old_number":1,"new_number":null,"text":"# Seed catalog rollout (archived)"},{"kind":"del","old_number":2,"new_number":null,"text":""},{"kind":"del","old_number":3,"new_number":null,"text":"Rollout finished. Keep the catalog sync notes in the current guide."},{"kind":"del","old_number":4,"new_number":null,"text":"Retire this archived copy."}]}]},
    {"path":"Sources/Legacy/Compatibility/SeedCatalogLegacyCompatibilityShimsAndMigrationHelpers.swift","old_path":"","status":"deleted","additions":0,"deletions":2,"binary":false,"truncated":false,"hunks":[{"old_start":1,"old_lines":2,"new_start":0,"new_lines":0,"header":"@@","lines":[{"kind":"del","old_number":1,"new_number":null,"text":"import Foundation"},{"kind":"del","old_number":2,"new_number":null,"text":"enum SeedCatalogLegacyCompatibilityShims { static let enabled = false }"}]}]}
    ]
    """)
    }

    private static func decode<T: Decodable>(_ json: String) -> T { try! JSONDecoder().decode(T.self, from: Data(json.utf8)) }
}

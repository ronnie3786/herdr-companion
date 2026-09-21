import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("PR Review wire decoding")
struct PRReviewDecodingTests {
    @Test("Summary uses enum-backed status and ranking state")
    func summaryDecodes() throws {
        let summary = try decode(
            PRReviewSummary.self,
            """
            {"id":"prr_0123456789ab","url":"https://dev.example.test/example-owner/garden-planner/pull/42","owner":"example-owner","repo":"garden-planner","number":42,"title":"Add seed catalog sync","author":"sam","base_ref":"main","head_ref":"seed-sync","base_sha":"base","head_sha":"head","github_state":"OPEN","is_draft":false,"status":"ready","ranking_state":"done","additions":8,"deletions":2,"changed_files":1,"revision":4,"running_runs":0,"document_count":2}
            """
        )

        #expect(summary.status == .ready)
        #expect(summary.rankingState == .done)
        #expect(summary.baseSHA == "base")
    }

    @Test("Unknown wire enums remain readable")
    func unknownEnumsDecode() throws {
        let summary = try decode(
            PRReviewSummary.self,
            """
            {"id":"prr_0123456789ab","status":"future-status","ranking_state":"future-ranking"}
            """
        )
        let impact = try decode(PRReviewImpact.self, "\"critical\"")

        #expect(summary.status == .unknown)
        #expect(summary.rankingState == .unknown)
        #expect(impact == .unknown)
    }

    @Test("File and flat skill-state shapes decode server keys")
    func fileAndSkillStateDecode() throws {
        let file = try decode(
            PRReviewFile.self,
            """
            {"path":"Sources/Garden.swift","old_path":"","status":"modified","additions":5,"deletions":1,"impact":"high","impact_reason":"entry point","guided_order":2,"guided_reason":"start here","viewed":true,"viewed_at":"2026-01-15T14:30:00Z","viewed_source":"github"}
            """
        )
        let state = try decode(
            PRReviewSkillState.self,
            """
            {"id":"review","title":"Review","kind":"review","runner":"pi","prompt_template":"prompt","command_template":"command","outputs":["report.md"],"description":"why","builtin":true,"enabled":true,"state":"ran","mark":{"state":"ran","actor":"sam","note":"checked","marked_at":"2026-01-15T14:30:00Z"},"run_count":3,"last_run_at":"2026-01-15T14:30:00Z","running":false}
            """
        )

        #expect(file.guidedOrder == 2)
        #expect(state.skill.id == "review")
        #expect(state.mark?.actor == "sam")
        #expect(state.runCount == 3)
    }

    @Test("Run, document, and event retain their complete wire shape")
    func runDocumentAndEventDecode() throws {
        let run = try decode(
            PRReviewRun.self,
            """
            {"id":"prun_0123456789ab","review_id":"prr_0123456789ab","skill_id":"review","skill_title":"Review","state":"finished","launch":"manual","command":"review","workspace_id":"workspace","tab_id":"tab","pane_id":"pane","actor":"sam","note":"done","error":null,"created_at":"2026-01-15T14:30:00Z","started_at":"2026-01-15T14:31:00Z","finished_at":"2026-01-15T14:32:00Z"}
            """
        )
        let document = try decode(
            PRReviewDocument.self,
            """
            {"id":"prdoc_0123456789ab","review_id":"prr_0123456789ab","run_id":"prun_0123456789ab","kind":"markdown","title":"Findings","media_type":"text/markdown","filename":"findings.md","url":null,"byte_size":12,"content_hash":"hash","origin":"skill","origin_path":null,"created_at":"2026-01-15T14:30:00Z","downloadable":true}
            """
        )
        let event = try decode(
            PRReviewEvent.self,
            """
            {"id":"prev_0123456789ab","sequence":3,"review_id":"prr_0123456789ab","type":"review.updated","summary":"Updated","payload":{"count":2},"created_at":"2026-01-15T14:30:00Z"}
            """
        )

        #expect(run.state == .finished)
        #expect(document.byteSize == 12)
        #expect(event.payload["count"] == .number(2))
    }

    @Test("Snapshot, list, and capabilities decode optional server capability fields")
    func snapshotListAndCapabilitiesDecode() throws {
        let snapshot = try decode(
            PRReviewSnapshot.self,
            """
            {"ok":true,"review":{"id":"prr_0123456789ab","status":"ready","ranking_state":"idle"},"files":[],"skills":[],"runs":[],"documents":[],"events":[]}
            """
        )
        let list = try decode(
            PRReviewListResponse.self,
            """
            {"ok":true,"reviews":[{"id":"prr_0123456789ab","status":"ready","ranking_state":"idle"}]}
            """
        )
        let capabilities = try decode(
            PRReviewCapabilities.self,
            """
            {"ok":true,"capabilities":["pr-review-v1"],"available":true,"skills":[],"gh_available":true,"runner":"pi","runner_available":true,"pi_available":true,"workspace_label":"PR Reviews","auto_rank":true,"sync_viewed_to_github":false}
            """
        )

        #expect(snapshot.review.id == "prr_0123456789ab")
        #expect(list.reviews.count == 1)
        #expect(capabilities.supportsV1)
        #expect(capabilities.syncViewedToGitHub == false)
    }

    @Test("Diff, file text, and findings use their snake-case response keys")
    func diffFileTextAndFindingsDecode() throws {
        let diff = try decode(
            PRReviewDiff.self,
            """
            {"ok":true,"review_id":"prr_0123456789ab","base_sha":"base","head_sha":"head","truncated":false,"files":[{"path":"Sources/Garden.swift","old_path":"","status":"modified","additions":1,"deletions":0,"binary":false,"truncated":false,"hunks":[{"old_start":1,"old_lines":1,"new_start":1,"new_lines":2,"header":"@@","lines":[{"kind":"add","old_number":null,"new_number":1,"text":"new"}]}]}]}
            """
        )
        let fileText = try decode(
            PRReviewFileText.self,
            """
            {"ok":true,"path":"Sources/Garden.swift","side":"after","start_line":4,"end_line":8,"total_lines":20,"text":"garden"}
            """
        )
        let findings = try decode(
            PRReviewFindings.self,
            """
            {"ok":true,"path":"Sources/Garden.swift","text":"No findings","document_ids":["prdoc_0123456789ab"]}
            """
        )

        #expect(diff.headSHA == "head")
        #expect(fileText.startLine == 4)
        #expect(findings.documentIDs == ["prdoc_0123456789ab"])
    }

    @Test("Added-file diffs and link documents accept null server fields")
    func nullableDiffAndLinkFieldsDecode() throws {
        let diff = try decode(
            PRReviewDiff.self,
            """
            {"ok":true,"review_id":"prr_0123456789ab","base_sha":"base","head_sha":"head","truncated":false,"files":[{"path":"Sources/NewGarden.swift","old_path":null,"status":"added","additions":4,"deletions":0,"binary":false,"truncated":false,"hunks":[]}]}
            """
        )
        let link = try decode(
            PRReviewDocument.self,
            """
            {"id":"prdoc_0123456789ab","review_id":"prr_0123456789ab","run_id":null,"kind":"link","title":"Fictional reference","media_type":"text/uri-list","filename":null,"url":"https://example.invalid/reference","byte_size":0,"content_hash":null,"origin":"user","origin_path":null,"created_at":"2026-01-15T14:30:00Z","downloadable":false}
            """
        )

        #expect(diff.files.first?.oldPath == nil)
        #expect(link.filename == nil)
        #expect(link.contentHash == nil)
    }

    @Test("Selection spans use the Companion old and new wire vocabulary")
    func selectionSpanWireSides() throws {
        let context = AssistantContext(
            source: .init(feature: "pr-review.diff", instanceId: "prr_0123456789ab"),
            items: [
                .init(
                    id: "selection",
                    kind: "text-selection.v1",
                    label: "Fictional selection",
                    text: "garden",
                    priority: "required",
                    locator: .init(
                        path: "Sources/Garden.swift",
                        spans: [
                            .init(side: PRReviewSide.before.wireSide, startLine: 4, endLine: 4),
                            .init(side: PRReviewSide.after.wireSide, startLine: 5, endLine: 5),
                        ]
                    )
                ),
            ]
        )
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as? [String: Any]
        let items = try #require(encoded?["items"] as? [[String: Any]])
        let locator = try #require(items[0]["locator"] as? [String: Any])
        let spans = try #require(locator["spans"] as? [[String: Any]])

        #expect(spans.map { $0["side"] as? String } == ["old", "new"])
    }

    private func decode<T: Decodable>(_ type: T.Type, _ string: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(string.utf8))
    }
}

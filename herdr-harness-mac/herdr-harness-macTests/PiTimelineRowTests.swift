import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Pi timeline rows")
struct PiTimelineRowTests {
    @Test("Turns flatten into one row per user message, output item, and working group")
    func flattensTurnsIntoRows() {
        let turns = [
            turn(id: "turn:1", items: [
                .thinking(thinking(id: "t1")),
                .tool(tool(id: "c1")),
                .assistant(assistant(id: "a1", text: "First answer")),
            ]),
            turn(id: "turn:2", items: [
                .assistant(assistant(id: "a2", text: "Second answer")),
            ], isActive: true),
        ]

        let rows = PiTimelineRow.rows(for: turns)

        #expect(rows.map(\.id) == [
            "turn:1|user",
            "turn:1|working:t1",
            "turn:1|output:a1",
            "turn:2|user",
            "turn:2|output:a2",
        ])
        #expect(rows.map(\.startsTurn) == [true, false, false, true, false])
        #expect(rows.map(\.isFirstInTimeline) == [true, false, false, false, false])
        #expect(rows[0].topSpacing == 0)
        #expect(rows[1].topSpacing == PiTimelineMetrics.itemSpacing)
        #expect(rows[3].topSpacing == HerdrProse.turnSpacing)
    }

    @Test("An active turn with no items gets the starting placeholder row")
    func activeEmptyTurnShowsStartingRow() {
        let rows = PiTimelineRow.rows(for: [turn(id: "turn:1", items: [], isActive: true)])

        #expect(rows.map(\.id) == ["turn:1|user", "turn:1|starting"])
        #expect(rows.last?.content == .starting)
    }

    @Test("A turn with nothing visible produces no rows")
    func invisibleTurnProducesNoRows() {
        var empty = turn(id: "turn:1", items: [])
        empty.user = nil

        #expect(PiTimelineRow.rows(for: [empty]).isEmpty)
    }

    @Test("Streaming a token changes exactly the row that owns the text")
    func tokenChangesOnlyItsRow() {
        let before = [
            turn(id: "turn:1", items: [
                .thinking(thinking(id: "t1")),
                .assistant(assistant(id: "a1", text: "Hel", status: .streaming)),
            ], isActive: true),
        ]
        var after = before
        after[0].items[1] = .assistant(assistant(id: "a1", text: "Hello", status: .streaming))
        after[0].itemsRevision += 1

        let rowsBefore = PiTimelineRow.rows(for: before)
        let rowsAfter = PiTimelineRow.rows(for: after)

        #expect(rowsBefore.count == 3)
        #expect(rowsBefore[0] == rowsAfter[0])
        #expect(rowsBefore[1] == rowsAfter[1])
        #expect(rowsBefore[2] != rowsAfter[2])
    }

    @MainActor
    @Test("Row views compare by row content so unchanged rows skip their body")
    func rowViewEquatableFollowsRowModel() {
        let rows = PiTimelineRow.rows(for: [turn(id: "turn:1", items: [.assistant(assistant(id: "a1", text: "Hi"))])])
        let view = PiTimelineRowView(row: rows[1])
        let same = PiTimelineRowView(row: rows[1])
        var changedRows = PiTimelineRow.rows(for: [turn(id: "turn:1", items: [.assistant(assistant(id: "a1", text: "Hi there"))])])
        let changed = PiTimelineRowView(row: changedRows.removeLast())

        #expect(view == same)
        #expect(view != changed)
    }

    @Test("Whitespace-only assistant events do not create gaps or split activity")
    func emptyAssistantRowsDoNotReserveSpace() {
        let rows = PiTimelineRow.rows(for: [turn(id: "turn:1", items: [
            .tool(tool(id: "c1")),
            .assistant(assistant(id: "empty", text: "\n\n \n", status: .streaming)),
            .tool(tool(id: "c2", status: .running)),
            .assistant(assistant(id: "visible", text: "Now the scenes.")),
        ], isActive: true)])

        #expect(rows.map(\.id) == ["turn:1|user", "turn:1|working:tool:c1", "turn:1|output:visible"])
        if case let .working(group) = rows[1].content {
            #expect(group.toolCount == 2)
            #expect(group.isLive)
        } else {
            Issue.record("Expected one uninterrupted activity group")
        }
    }

    @Test("An empty failed assistant response still presents its error")
    func emptyFailureRemainsVisible() {
        let failed = assistant(id: "failed", text: "", status: .failed("Service unavailable"))
        let rows = PiTimelineRow.rows(for: [turn(id: "turn:1", items: [.assistant(failed)])])

        #expect(rows.last?.content == .output(.assistant(failed)))
    }

    @Test("Grouped timeline shows one activity row and a settled final answer")
    func groupedTimelineHasOneActivityRowAndFinalAnswer() {
        let rows = PiTimelineRow.rows(
            for: [turn(id: "turn:1", items: [
                .assistant(assistant(id: "commentary", text: "I’ll inspect that.")),
                .thinking(thinking(id: "thinking")),
                .tool(tool(id: "command")),
                .assistant(assistant(id: "answer", text: "The fix is ready.")),
            ])],
            groupAllActivity: true
        )

        #expect(rows.map(\.id) == [
            "turn:1|user",
            "turn:1|working:turn:turn:1",
            "turn:1|output:answer",
        ])
        guard case let .working(group) = rows[1].content else {
            Issue.record("Expected one grouped activity row")
            return
        }
        #expect(group.items.map(\.id) == ["commentary", "thinking", "tool:command"])
    }

    @Test("A compaction notice stays outside collapsed Clanking groups")
    func compactionNoticeStaysOutsideWorkingGroup() {
        let notice = PiConversationNotice(
            id: "compact-1",
            title: "Context compacted",
            detail: "Synthetic summary",
            tone: .neutral,
            timestamp: nil
        )
        let rows = PiTimelineRow.rows(
            for: [turn(id: "turn:1", items: [
                .tool(tool(id: "command")),
                .notice(notice),
                .assistant(assistant(id: "answer", text: "Working from the compacted context.")),
            ])],
            groupAllActivity: true
        )

        #expect(rows.map(\.id) == [
            "turn:1|user",
            "turn:1|working:turn:turn:1",
            "turn:1|output:compact-1",
            "turn:1|output:answer",
        ])
        guard case let .working(group) = rows[1].content else {
            Issue.record("Expected the collapsed activity group")
            return
        }
        #expect(!group.items.contains { item in
            if case .notice = item { return true }
            return false
        })
        #expect(rows[2].content == .output(.notice(notice)))
    }

    @Test("Grouped timeline does not expose a completed text block while its turn is active")
    func groupedTimelineHidesTextUntilTurnFinishes() {
        let rows = PiTimelineRow.rows(
            for: [turn(
                id: "turn:1",
                items: [.assistant(assistant(id: "answer", text: "Looks final", status: .complete))],
                isActive: true
            )],
            groupAllActivity: true
        )

        #expect(rows.map(\.id) == ["turn:1|user", "turn:1|working:turn:turn:1"])
        #expect(!rows.contains { row in
            if case .output(.assistant(_)) = row.content { return true }
            return false
        })
    }

    @Test("The mounted window keeps only the newest rows until earlier rows are requested")
    func windowBoundsMountedRows() {
        let turns = (1...5).map { index in
            turn(id: "turn:\(index)", items: [.assistant(assistant(id: "a\(index)", text: "Answer \(index)"))])
        }
        let rows = PiTimelineRow.rows(for: turns)
        #expect(rows.count == 10)

        let bounded = PiTimelineWindow(rows: rows, showsEarlierRows: false, limit: 4)
        #expect(bounded.hiddenCount == 6)
        #expect(bounded.rows.map(\.id) == ["turn:4|user", "turn:4|output:a4", "turn:5|user", "turn:5|output:a5"])
        #expect(bounded.rows[0].isFirstInTimeline)
        #expect(bounded.rows[0].topSpacing == 0)
        #expect(bounded.rows[2].topSpacing == HerdrProse.turnSpacing)

        let full = PiTimelineWindow(rows: rows, showsEarlierRows: true, limit: 4)
        #expect(full.hiddenCount == 0)
        #expect(full.rows == rows)

        let small = PiTimelineWindow(rows: rows, showsEarlierRows: false, limit: 100)
        #expect(small.hiddenCount == 0)
        #expect(small.rows == rows)
    }

    private func turn(id: String, items: [PiConversationItem], isActive: Bool = false) -> PiConversationTurn {
        PiConversationTurn(
            id: id,
            user: PiUserMessage(id: "\(id):user", text: "Prompt", timestamp: nil),
            items: items,
            itemsRevision: 1,
            startedAt: nil,
            isActive: isActive
        )
    }

    private func assistant(id: String, text: String, status: PiAssistantBlock.Status = .complete) -> PiAssistantBlock {
        PiAssistantBlock(id: id, text: text, status: status, timestamp: nil)
    }

    private func thinking(id: String) -> PiThinkingBlock {
        PiThinkingBlock(id: id, text: "Thinking", isStreaming: false, isRedacted: false, startedAt: nil)
    }

    private func tool(id: String, status: PiToolInvocation.Status = .succeeded) -> PiToolInvocation {
        PiToolInvocation(
            id: "tool:\(id)",
            callID: id,
            name: "bash",
            arguments: nil,
            result: nil,
            status: status,
            startedAt: nil,
            finishedAt: nil
        )
    }
}

import Testing
@testable import herdr_harness_mac

@Suite("Pi turn segmentation")
struct PiTurnSegmentationTests {
    @Test("All output items remain visible and ordered")
    func allOutputItemsRemainOutputSegments() {
        let items = [assistant("assistant:1"), notice("notice:1", tone: .neutral), assistant("assistant:2")]

        let segments = PiTurnSegmentation.segments(for: items)

        #expect(segments.map(\.id) == ["output:assistant:1", "output:notice:1", "output:assistant:2"])
    }

    @Test("A contiguous working run forms one group")
    func contiguousWorkingItemsFormOneGroup() {
        let segments = PiTurnSegmentation.segments(for: [thinking("thinking:1"), tool("tool:1"), tool("tool:2")])

        guard case let .working(group) = segments.first else {
            Issue.record("Expected one working group")
            return
        }
        #expect(segments.count == 1)
        #expect(group.stepCount == 3)
        #expect(group.toolCount == 2)
        #expect(group.thinkingCount == 1)
    }

    @Test("Working groups preserve their position between output messages")
    func workingGroupsPreserveChronologicalOrder() {
        let items = [
            thinking("thinking:1"),
            assistant("assistant:1"),
            tool("tool:1"),
            tool("tool:2"),
            assistant("assistant:2")
        ]

        let segments = PiTurnSegmentation.segments(for: items)

        #expect(segments.map(\.id) == ["working:thinking:1", "output:assistant:1", "working:tool:1", "output:assistant:2"])
    }

    @Test("Segmentation never drops an item")
    func segmentationNeverDropsItems() {
        let items = [
            thinking("thinking:1"),
            tool("tool:1"),
            assistant("assistant:1"),
            notice("notice:1", tone: .warning),
            tool("tool:2")
        ]

        let flattened = PiTurnSegmentation.segments(for: items).flatMap { segment in
            switch segment {
            case let .output(item): [item]
            case let .working(group): group.items
            }
        }

        #expect(flattened.map(\.id) == items.map(\.id))
    }

    @Test("A working group's identity stays stable when tools append")
    func workingGroupIdentityStaysStableWhenToolsAppend() {
        let initial = PiTurnSegmentation.segments(for: [thinking("thinking:1"), tool("tool:1")])
        let appended = PiTurnSegmentation.segments(for: [thinking("thinking:1"), tool("tool:1"), tool("tool:2")])

        guard case let .working(initialGroup) = initial.first,
              case let .working(appendedGroup) = appended.first else {
            Issue.record("Expected working groups")
            return
        }
        #expect(initialGroup.id == appendedGroup.id)
    }

    @Test("Live state follows pending tools and streaming thinking")
    func liveStateFollowsWorkingItemState() {
        #expect(workingGroup([tool("tool:waiting", status: .waiting)]).isLive)
        #expect(workingGroup([tool("tool:running", status: .running)]).isLive)
        #expect(workingGroup([thinking("thinking:streaming", isStreaming: true)]).isLive)
        #expect(!workingGroup([thinking("thinking:settled"), tool("tool:succeeded", status: .succeeded)]).isLive)
    }

    @Test("Failed tools are counted and surfaced")
    func failedToolsAreCounted() {
        let group = workingGroup([tool("tool:1", status: .failed), tool("tool:2", status: .failed), tool("tool:3", status: .succeeded)])

        #expect(group.failureCount == 2)
        #expect(group.hasFailure)
    }

    @Test("The latest tool supplies the group title")
    func latestToolSuppliesGroupTitle() {
        let tools = workingGroup([thinking("thinking:1"), tool("tool:read", name: "read"), tool("tool:command", name: "bash")])
        let thinkingOnly = workingGroup([thinking("thinking:2")])

        #expect(tools.latestToolTitle == "Command")
        #expect(thinkingOnly.latestToolTitle == nil)
    }

    @Test("Only thinking and tool items are working activity")
    func itemWorkingClassification() {
        #expect(thinking("thinking:1").isWorking)
        #expect(tool("tool:1").isWorking)
        #expect(!assistant("assistant:complete").isWorking)
        #expect(!assistant("assistant:failed", status: .failed("Provider unavailable")).isWorking)
        for tone in [PiConversationNotice.Tone.neutral, .warning, .error] {
            #expect(!notice("notice:\(tone)", tone: tone).isWorking)
        }
    }

    @Test("Grouped mode keeps all assistant text hidden until the turn settles")
    func groupedModeWaitsForTurnSettlement() {
        let turn = PiConversationTurn(
            id: "turn:1",
            user: PiUserMessage(id: "user:1", text: "Prompt", timestamp: nil),
            items: [
                assistant("commentary:1"),
                tool("tool:1"),
                assistant("answer:1"),
            ],
            startedAt: nil,
            isActive: true
        )

        let segments = PiTurnSegmentation.segments(for: turn, groupAllActivity: true)

        #expect(segments.count == 1)
        guard case let .working(group) = segments.first else {
            Issue.record("Expected one grouped activity disclosure")
            return
        }
        #expect(group.id == "working:turn:turn:1")
        #expect(group.items.map(\.id) == ["commentary:1", "tool:1", "answer:1"])
        #expect(group.isLive)
    }

    @Test("Grouped mode releases only the terminal answer after settlement")
    func groupedModeReleasesOnlyTerminalAnswer() {
        let turn = PiConversationTurn(
            id: "turn:1",
            user: PiUserMessage(id: "user:1", text: "Prompt", timestamp: nil),
            items: [
                assistant("commentary:1"),
                tool("tool:1"),
                notice("notice:1", tone: .warning),
                assistant("answer:1"),
            ],
            startedAt: nil,
            isActive: false
        )

        let segments = PiTurnSegmentation.segments(for: turn, groupAllActivity: true)

        #expect(segments.map(\.id) == [
            "working:turn:turn:1",
            "output:notice:1",
            "output:answer:1",
        ])
        guard case let .working(group) = segments.first else {
            Issue.record("Expected grouped interim activity")
            return
        }
        #expect(group.items.map(\.id) == ["commentary:1", "tool:1"])
        #expect(!group.isLive)
        #expect(group.stepCount == 2)
    }

    @Test("Grouped identity survives the final answer moving out of activity")
    func groupedIdentitySurvivesSettlement() {
        var turn = PiConversationTurn(
            id: "turn:stable",
            user: PiUserMessage(id: "user:1", text: "Prompt", timestamp: nil),
            items: [tool("tool:1"), assistant("answer:1")],
            startedAt: nil,
            isActive: true
        )
        let active = PiTurnSegmentation.segments(for: turn, groupAllActivity: true)
        turn.isActive = false
        let settled = PiTurnSegmentation.segments(for: turn, groupAllActivity: true)

        #expect(active.first?.id == "working:turn:turn:stable")
        #expect(active.first?.id == settled.first?.id)
        #expect(settled.last?.id == "output:answer:1")
    }

    @Test("Grouped failures stay in the disclosure summary")
    func groupedFailuresStayVisible() {
        let turn = PiConversationTurn(
            id: "turn:failed",
            user: PiUserMessage(id: "user:1", text: "Prompt", timestamp: nil),
            items: [
                tool("tool:failed", status: .failed),
                assistant("assistant:failed", status: .failed("Provider unavailable")),
                notice("notice:error", tone: .error),
            ],
            startedAt: nil,
            isActive: false
        )

        let segments = PiTurnSegmentation.segments(for: turn, groupAllActivity: true)

        guard case let .working(group) = segments.first else {
            Issue.record("Expected failures in one activity disclosure")
            return
        }
        #expect(segments.map(\.id) == [
            "working:turn:turn:failed",
            "output:assistant:failed",
            "output:notice:error",
        ])
        #expect(group.failureCount == 1)
        #expect(group.hasFailure)
    }

    @Test("Grouped mode releases every text part of the terminal message")
    func groupedModeReleasesMultipartFinalAnswer() {
        let turn = PiConversationTurn(
            id: "turn:multipart",
            user: PiUserMessage(id: "user:1", text: "Prompt", timestamp: nil),
            items: [
                assistant("commentary:text:0", stopReason: "toolUse"),
                tool("tool:1"),
                assistant("final:text:0", stopReason: "stop"),
                assistant("final:text:1", stopReason: "stop"),
            ],
            startedAt: nil,
            isActive: false
        )

        let segments = PiTurnSegmentation.segments(for: turn, groupAllActivity: true)

        #expect(segments.map(\.id) == [
            "working:turn:turn:multipart",
            "output:final:text:0",
            "output:final:text:1",
        ])
        guard case let .working(group) = segments.first else {
            Issue.record("Expected commentary to remain grouped")
            return
        }
        #expect(group.items.map(\.id) == ["commentary:text:0", "tool:1"])
    }

    @Test("Tool-use commentary is not promoted when no final answer follows")
    func toolUseCommentaryIsNotPromoted() {
        let turn = PiConversationTurn(
            id: "turn:tool-use",
            user: PiUserMessage(id: "user:1", text: "Prompt", timestamp: nil),
            items: [assistant("commentary:text:0", stopReason: "toolUse")],
            startedAt: nil,
            isActive: false
        )

        let segments = PiTurnSegmentation.segments(for: turn, groupAllActivity: true)

        #expect(segments.map(\.id) == ["working:turn:turn:tool-use"])
        guard case let .working(group) = segments.first else {
            Issue.record("Expected commentary to remain grouped")
            return
        }
        #expect(group.items.map(\.id) == ["commentary:text:0"])
    }

    @Test("Neutral notices after an explicit multipart stop do not hide the answer")
    func neutralNoticeAfterExplicitStopPreservesFinalAnswer() {
        let turn = PiConversationTurn(
            id: "turn:notice",
            user: PiUserMessage(id: "user:1", text: "Prompt", timestamp: nil),
            items: [
                assistant("commentary:text:0", stopReason: "toolUse"),
                tool("tool:1"),
                assistant("final:text:0", stopReason: "stop"),
                assistant("final:text:1", stopReason: "stop"),
                notice("notice:info", tone: .neutral),
            ],
            startedAt: nil,
            isActive: false
        )

        let segments = PiTurnSegmentation.segments(for: turn, groupAllActivity: true)

        #expect(segments.map(\.id) == [
            "working:turn:turn:notice",
            "output:final:text:0",
            "output:final:text:1",
            "output:notice:info",
        ])
    }

    @Test("A trailing error notice prevents stale answer promotion")
    func trailingErrorPreventsStaleAnswerPromotion() {
        let turn = PiConversationTurn(
            id: "turn:error",
            user: PiUserMessage(id: "user:1", text: "Prompt", timestamp: nil),
            items: [
                assistant("commentary:text:0", stopReason: "toolUse"),
                tool("tool:1"),
                assistant("stale:text:0", stopReason: "stop"),
                notice("notice:error", tone: .error),
            ],
            startedAt: nil,
            isActive: false
        )

        let segments = PiTurnSegmentation.segments(for: turn, groupAllActivity: true)

        #expect(segments.map(\.id) == [
            "working:turn:turn:error",
            "output:notice:error",
        ])
        guard case let .working(group) = segments.first else {
            Issue.record("Expected stale assistant text to remain grouped")
            return
        }
        #expect(group.items.map(\.id) == [
            "commentary:text:0",
            "tool:1",
            "stale:text:0",
        ])
    }

    @Test("An interrupted conclusion leaves commentary grouped and errors visible")
    func interruptedConclusionDoesNotPromoteCommentary() {
        let turn = PiConversationTurn(
            id: "turn:aborted",
            user: PiUserMessage(id: "user:1", text: "Prompt", timestamp: nil),
            items: [
                assistant("commentary:text:0", stopReason: "toolUse"),
                assistant(
                    "aborted:text:0",
                    status: .failed("Interrupted"),
                    stopReason: "aborted"
                ),
                notice("aborted:notice", tone: .warning),
            ],
            startedAt: nil,
            isActive: false
        )

        let segments = PiTurnSegmentation.segments(for: turn, groupAllActivity: true)

        #expect(segments.map(\.id) == [
            "working:turn:turn:aborted",
            "output:aborted:text:0",
            "output:aborted:notice",
        ])
        guard case let .working(group) = segments.first else {
            Issue.record("Expected commentary to remain grouped")
            return
        }
        #expect(group.items.map(\.id) == ["commentary:text:0"])
    }

    @Test("Whole-turn grouping remains opt-in for compatibility")
    func wholeTurnGroupingDefaultsOff() {
        #expect(!ChatActivityPreferences.defaultGroupAllClankingActivity)
    }

    private func workingGroup(_ items: [PiConversationItem]) -> PiWorkingGroup {
        let segments = PiTurnSegmentation.segments(for: items)
        guard case let .working(group) = segments.first else {
            fatalError("Expected working items to form a group")
        }
        return group
    }

    private func assistant(
        _ id: String,
        status: PiAssistantBlock.Status = .complete,
        stopReason: String? = nil
    ) -> PiConversationItem {
        .assistant(PiAssistantBlock(
            id: id,
            text: "Output",
            status: status,
            timestamp: nil,
            stopReason: stopReason
        ))
    }

    private func thinking(_ id: String, isStreaming: Bool = false) -> PiConversationItem {
        .thinking(PiThinkingBlock(id: id, text: "Thinking", isStreaming: isStreaming, isRedacted: false, startedAt: nil))
    }

    private func tool(
        _ id: String,
        name: String = "read",
        status: PiToolInvocation.Status = .succeeded
    ) -> PiConversationItem {
        .tool(PiToolInvocation(id: id, callID: "call:\(id)", name: name, arguments: nil, result: nil, status: status, startedAt: nil, finishedAt: nil))
    }

    private func notice(_ id: String, tone: PiConversationNotice.Tone) -> PiConversationItem {
        .notice(PiConversationNotice(id: id, title: "Notice", detail: nil, tone: tone, timestamp: nil))
    }
}

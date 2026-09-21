import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Car mode status lines")
struct CarModeSummaryTests {
    // MARK: - Priority ladder

    @Test("A blocked agent says it is waiting, even with no transcript")
    func blockedWithoutTranscript() {
        let summary = derive(status: .blocked)

        #expect(summary.kind == .question("Waiting for your answer."))
        #expect(summary.headline == "Waiting for your answer.")
        #expect(summary.isQuestion)
        #expect(!summary.hasPlayableResponse)
    }

    @Test("A pending question is read out with its title")
    func pendingQuestion() {
        let summary = derive(
            interactions: [
                PiPendingInteraction(
                    id: "q1",
                    kind: .select,
                    title: "Keep the demo station in metric?",
                    message: nil,
                    options: ["Metric", "Both"],
                    placeholder: nil
                )
            ]
        )

        #expect(summary.kind == .question("Waiting for your answer: Keep the demo station in metric?"))
        #expect(summary.isQuestion)
    }

    @Test("A blocked pane outranks a running turn")
    func questionBeatsWorking() {
        let summary = derive(status: .blocked, phase: .working, items: [.tool(runningTool("bash", ["command": "swift test"]))])

        #expect(summary.isQuestion)
    }

    @Test("A running command reads like a sentence")
    func runningCommand() {
        let summary = derive(
            status: .working,
            phase: .working,
            items: [.tool(runningTool("bash", ["command": "swift test"]))]
        )

        #expect(summary.kind == .activity("Running swift test"))
    }

    @Test("A running file operation names the file")
    func runningFileRead() {
        let summary = derive(
            status: .working,
            phase: .working,
            items: [.tool(runningTool("read", ["path": "Sources/Garden/SeedPicker.swift"]))]
        )

        #expect(summary.kind == .activity("Reading Sources/Garden/SeedPicker.swift"))
    }

    @Test("Thinking is reported as thinking")
    func thinking() {
        let summary = derive(status: .working, phase: .working, items: [.thinking(thinkingBlock())])

        #expect(summary.kind == .activity("Thinking…"))
    }

    @Test("Working with nothing more specific stays short")
    func workingWithoutDetail() {
        let summary = derive(status: .working, phase: .working)

        #expect(summary.kind == .working)
        #expect(summary.headline == "Working…")
    }

    @Test("Compaction replaces a running step, because Pi is not taking work yet")
    func compactionWins() {
        let summary = derive(
            status: .working,
            phase: .working,
            items: [.tool(runningTool("bash", ["command": "swift test"]))],
            compaction: PiCompactionActivity(reason: .threshold, willRetry: false)
        )

        #expect(summary.kind == .compacting("Compacting context automatically…"))
    }

    @Test("A failure notice becomes a failure line")
    func failureNotice() {
        let summary = derive(
            status: .working,
            phase: .failed,
            items: [.notice(PiConversationNotice(id: "n1", title: "The sample checks could not finish.", detail: nil, tone: .error, timestamp: nil))]
        )

        #expect(summary.kind == .failed("Run failed: The sample checks could not finish."))
        #expect(summary.isFailure)
    }

    @Test("A ready agent leads with the first line of its answer, past any heading")
    func answerHeadline() {
        let summary = derive(
            status: .done,
            items: [.assistant(assistantBlock("## Done\n\nThe **demo export** is ready: three fictional books.\n\n- winter\n- summer"))]
        )

        #expect(summary.kind == .answer("The demo export is ready: three fictional books."))
        #expect(summary.hasPlayableResponse)
        #expect(summary.response?.contains("**demo export**") == true)
    }

    @Test("A heading-only answer still says something")
    func headingOnlyAnswer() {
        let summary = derive(status: .done, items: [.assistant(assistantBlock("## Done"))])

        #expect(summary.kind == .answer("Done"))
    }

    @Test("With no answer yet, the last thing you asked is echoed back")
    func promptEcho() {
        let summary = derive(
            status: .idle,
            user: "Export the example book list as a table I can review."
        )

        #expect(summary.kind == .prompt("You asked: Export the example book list as a table I can review."))
        #expect(summary.asked == "Export the example book list as a table I can review.")
    }

    @Test("An agent with nothing readable is simply idle")
    func idleFallback() {
        let summary = derive()

        #expect(summary.kind == .idle)
        #expect(summary.headline == "Idle")
        #expect(!summary.hasPlayableResponse)
    }

    @Test("A whitespace-only answer is not playable")
    func whitespaceAnswerIsNotPlayable() {
        let summary = derive(status: .done, items: [.assistant(assistantBlock("   \n  "))])

        #expect(!summary.hasPlayableResponse)
        #expect(summary.kind == .idle)
    }

    // MARK: - Text flattening

    @Test("Flattening removes fences, bullets, links, emphasis, and table noise")
    func flattening() {
        let source = """
        ## Heading

        Read the [sample table](https://example.invalid/table?query=1) first.

        ```swift
        let value = 1
        ```

        - first item
        - second item

        1. numbered
        | name | note |
        | --- | --- |
        | herb | mint |
        """

        let flattened = CarModeText.flattened(source)

        #expect(flattened.contains("Heading"))
        #expect(flattened.contains("Read the sample table first."))
        #expect(flattened.contains("first item second item"))
        #expect(flattened.contains("numbered"))
        #expect(!flattened.contains("let value"))
        #expect(!flattened.contains("https://"))
        #expect(!flattened.contains("##"))
        #expect(!flattened.contains("\n"))
    }

    @Test("One line truncates at a word boundary inside the limit")
    func truncation() {
        let source = "The demo export is ready: three fictional books with notes and a suggested reading order that runs long."

        let line = try? #require(CarModeText.oneLine(source, limit: 40))

        #expect(line?.count ?? 0 <= 40)
        #expect(line?.hasSuffix("…") == true)
        #expect(line?.hasSuffix(" …") == false)
        #expect(CarModeText.oneLine("   \n ", limit: 40) == nil)
    }

    @Test("A code-only answer has no readable line")
    func codeOnlyAnswer() {
        #expect(CarModeText.firstLine(of: "```\nlet value = 1\n```") == nil)
    }

    @Test("A bare URL keeps its host instead of its query")
    func links() {
        let flattened = CarModeText.flattened("See [the sample](https://example.invalid/path?token=secret) for details.")
        #expect(flattened == "See the sample for details.")
    }

    // MARK: - Fixtures

    private func derive(
        status: AgentStatus = .idle,
        phase: PiConversationPhase = .idle,
        items: [PiConversationItem] = [],
        user: String? = nil,
        interactions: [PiPendingInteraction] = [],
        compaction: PiCompactionActivity? = nil,
        bridgeConnected: Bool = true
    ) -> CarAgentSummary {
        CarAgentSummary.derive(
            pane: pane(status: status),
            turns: [turn(user: user, items: items)],
            phase: phase,
            pendingInteractions: interactions,
            compactionActivity: compaction,
            bridgeConnected: bridgeConnected
        )
    }

    private func pane(status: AgentStatus) -> HerdrPane {
        HerdrPane(
            paneID: "w1:p1",
            terminalID: "w1:p1",
            workspaceID: "w1",
            tabID: "w1:t1",
            focused: true,
            agentStatus: status,
            revision: 1,
            cwd: "/tmp/herdr-demo",
            foregroundCWD: nil,
            label: nil,
            title: "Plan a fictitious herb garden",
            agent: "pi",
            displayAgent: "Pi",
            terminalTitle: nil,
            terminalTitleStripped: nil
        )
    }

    private func turn(user: String?, items: [PiConversationItem]) -> PiConversationTurn {
        PiConversationTurn(
            id: "turn-1",
            user: user.map { PiUserMessage(id: "u1", text: $0, timestamp: nil) },
            items: items,
            startedAt: nil,
            isActive: false
        )
    }

    private func assistantBlock(_ text: String, status: PiAssistantBlock.Status = .complete) -> PiAssistantBlock {
        PiAssistantBlock(id: "a1", text: text, status: status, timestamp: nil)
    }

    private func runningTool(_ name: String, _ arguments: [String: String]) -> PiToolInvocation {
        PiToolInvocation(
            id: "t1",
            callID: "call-1",
            name: name,
            arguments: .object(arguments.mapValues { .string($0) }),
            result: nil,
            status: .running,
            startedAt: nil,
            finishedAt: nil
        )
    }

    private func thinkingBlock() -> PiThinkingBlock {
        PiThinkingBlock(id: "think-1", text: "Considering the sample layout", isStreaming: true, isRedacted: false, startedAt: nil)
    }
}

import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Main chat skims")
@MainActor
struct ChatSkimTests {
    private var source: ChatSkimSource {
        ChatSkimSource(messageID: "final:text:0", reply: SkimReplyFixtures.reply, question: "Why did recovery stop?")
    }

    @Test("Only settled final text is skimmed, with the original question")
    func eligibleSources() {
        let commentary = PiAssistantBlock(id: "commentary:text:0", text: "I am looking into it.", status: .complete, stopReason: "toolUse")
        let final = PiAssistantBlock(id: source.messageID, text: source.reply, status: .complete, stopReason: "stop")
        var turn = PiConversationTurn(id: "turn", user: .init(id: "user", text: source.question!, timestamp: nil),
                                      items: [.assistant(commentary), .assistant(final)], isActive: false)
        #expect(ChatSkimSource.sources(in: turn) == [source.messageID: source])
        let rows = PiTimelineRow.rows(for: [turn])
        #expect(rows.compactMap(\.skimSource) == [source])
        turn.isActive = true
        #expect(ChatSkimSource.sources(in: turn).isEmpty)
        turn.isActive = false
        turn.items = [.assistant(PiAssistantBlock(id: "failed", text: source.reply, status: .failed("Stopped")))]
        #expect(ChatSkimSource.sources(in: turn).isEmpty)
    }

    @Test("A pending skim resolves once and repeated row loads share the result")
    func cachedLoad() async {
        let coordinator = ChatSkimCoordinator(pollInterval: .milliseconds(1))
        var requests = 0
        var polls = 0
        let transport = ChatSkimTransport(capabilities: { .init(enabled: true, minWords: 80) }, request: { reply, question in
            #expect(reply == source.reply && question == source.question)
            requests += 1
            return .init(id: "job", skim: .init(status: .pending))
        }, fetch: { id in
            #expect(id == "job")
            polls += 1
            return .init(id: id, skim: SkimReplyFixtures.skim)
        })
        async let first: Void = coordinator.load(source, transport: transport)
        async let second: Void = coordinator.load(source, transport: transport)
        _ = await (first, second)
        await coordinator.load(source, transport: transport)
        #expect(requests == 1 && polls == 1)
        #expect(coordinator.values[source.id]?.status == .ready)
    }

    @Test("Older companions and short replies keep their full text")
    func unsupportedAndShort() async {
        let coordinator = ChatSkimCoordinator()
        var requests = 0
        let unsupported = ChatSkimTransport(capabilities: { throw APIError.server(status: 404, message: "Unavailable") },
                                            request: { _, _ in requests += 1; return .init(id: nil, skim: nil) },
                                            fetch: { _ in .init(id: nil, skim: nil) })
        await coordinator.load(source, transport: unsupported)
        #expect(requests == 0 && coordinator.values.isEmpty)
        let short = ChatSkimSource(messageID: "short", reply: "Done.", question: nil)
        let available = ChatSkimTransport(capabilities: { .init(enabled: true, minWords: 80) }, request: unsupported.request, fetch: unsupported.fetch)
        await ChatSkimCoordinator().load(short, transport: available)
        #expect(requests == 0)
    }

    @Test("A failed capability lookup can recover after reconnect or a companion upgrade")
    func capabilityRecovery() async {
        let coordinator = ChatSkimCoordinator()
        var probes = 0
        var requests = 0
        let transport = ChatSkimTransport(capabilities: {
            probes += 1
            if probes == 1 { throw APIError.server(status: 404, message: "Unavailable") }
            return .init(enabled: true, minWords: 80)
        }, request: { _, _ in
            requests += 1
            return .init(id: "ready", skim: SkimReplyFixtures.skim)
        }, fetch: { _ in .init(id: nil, skim: nil) })
        await coordinator.load(source, transport: transport)
        await coordinator.load(source, transport: transport)
        #expect(probes == 2 && requests == 1)
        #expect(coordinator.values[source.id]?.status == .ready)
    }

    @Test("A stuck job stops polling and falls back to the original")
    func stuckJob() async {
        let coordinator = ChatSkimCoordinator(pollInterval: .milliseconds(1), pollLimit: 3)
        var polls = 0
        let transport = ChatSkimTransport(capabilities: { .init(enabled: true, minWords: 80) },
            request: { _, _ in .init(id: "job", skim: .init(status: .pending)) },
            fetch: { id in polls += 1; return .init(id: id, skim: .init(status: .pending)) })
        await coordinator.load(source, transport: transport)
        #expect(polls == 3)
        #expect(coordinator.values[source.id]?.status == .failed)
    }

    @Test("Long histories run at most two skim jobs at a time")
    func boundedConcurrency() async {
        let coordinator = ChatSkimCoordinator()
        var active = 0
        var maximum = 0
        var requests = 0
        let transport = ChatSkimTransport(capabilities: { .init(enabled: true, minWords: 80) }, request: { _, _ in
            active += 1
            maximum = max(maximum, active)
            requests += 1
            try? await Task.sleep(for: .milliseconds(10))
            active -= 1
            return .init(id: "ready", skim: SkimReplyFixtures.skim)
        }, fetch: { _ in .init(id: nil, skim: nil) })
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                let item = ChatSkimSource(messageID: "reply-\(index)", reply: source.reply, question: nil)
                group.addTask { await coordinator.load(item, transport: transport) }
            }
        }
        #expect(requests == 8 && maximum == 2)
    }
}

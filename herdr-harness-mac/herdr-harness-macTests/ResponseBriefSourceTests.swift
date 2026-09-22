import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Response brief source and request")
struct ResponseBriefSourceTests {
    @Test("Final source stays byte exact and excludes thinking and tool material")
    func exactFinalSource() throws {
        let turns = [
            PiConversationTurn(
                id: "previous",
                user: PiUserMessage(id: "u1", text: "Earlier question", timestamp: nil),
                items: [.assistant(.init(id: "a1", text: "Earlier answer", status: .complete))],
                isActive: false
            ),
            PiConversationTurn(
                id: "target",
                user: PiUserMessage(id: "u2", text: "Current question", timestamp: nil),
                items: [
                    .thinking(.init(id: "thinking", text: "hidden reasoning", isStreaming: false, isRedacted: false, startedAt: nil)),
                    .tool(.init(id: "tool", callID: "call", name: "read", arguments: nil, result: .string("tool output"), status: .succeeded, startedAt: nil, finishedAt: nil)),
                    .assistant(.init(id: "a2", text: "  exact\r\nanswer  \n", status: .complete, stopReason: "stop")),
                ],
                isActive: false
            ),
        ]

        let source = try #require(ResponseBriefSource.latest(
            turns: turns,
            machineID: "synthetic-machine",
            paneID: "w1:p2",
            sessionID: "01a00000-0000-7000-8000-000000000001"
        ))
        #expect(source.text == "  exact\r\nanswer  \n")
        #expect(source.currentUserText == "Current question")
        #expect(source.previousUserText == "Earlier question")
        #expect(source.previousAssistantText == "Earlier answer")
        #expect(!source.text.contains("hidden reasoning"))
        #expect(!source.text.contains("tool output"))
    }

    @Test("Completed sources are chronological and preserve every text part from only the final message")
    func completedSourcesPreserveFinalMessageParts() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try snapshot(
            entries: #"""
            [
              {"type":"message","id":"u1","message":{"role":"user","content":"First question"}},
              {"type":"message","id":"a1","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"First answer"}]}},
              {"type":"message","id":"u2","message":{"role":"user","content":"Current question"}},
              {"type":"message","id":"commentary","message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"text","text":"I will inspect."},{"type":"toolCall","id":"call-1","name":"read","arguments":{}}]}},
              {"type":"message","id":"tool-result","message":{"role":"toolResult","toolCallId":"call-1","toolName":"read","content":"untrusted tool output"}},
              {"type":"message","id":"final","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"Final part one.  "},{"type":"text","text":"\r\nFinal part two.\n"}]}}
            ]
            """#
        ))

        let sources = ResponseBriefSource.completedSources(
            turns: reducer.turns,
            machineID: "synthetic-machine",
            paneID: "w1:p2",
            sessionID: "01a00000-0000-7000-8000-000000000001"
        )

        #expect(sources.map(\.responseID) == ["a1", "final"])
        #expect(sources.last?.text == "Final part one.  \r\nFinal part two.\n")
        #expect(sources.last?.previousUserText == "First question")
        #expect(sources.last?.previousAssistantText == "First answer")
        #expect(sources.last?.text.contains("I will inspect") == false)
        #expect(sources.last?.text.contains("tool output") == false)
    }

    @Test("Latest source matches the chronological result across a long synthetic history")
    func latestMatchesCompletedSources() throws {
        var turns = (0..<2_000).map { index in
            PiConversationTurn(
                id: "turn-\(index)",
                user: PiUserMessage(id: "user-\(index)", text: "Question \(index)", timestamp: nil),
                items: [.assistant(.init(
                    id: "answer-\(index)",
                    text: "Answer \(index)",
                    status: .complete,
                    stopReason: "stop"
                ))],
                isActive: false
            )
        }
        turns.append(PiConversationTurn(
            id: "active-tail",
            user: PiUserMessage(id: "active-user", text: "Still streaming", timestamp: nil),
            items: [.assistant(.init(id: "active-answer", text: "Partial", status: .streaming))],
            isActive: true
        ))

        let completed = ResponseBriefSource.completedSources(
            turns: turns,
            machineID: "synthetic-machine",
            paneID: "w1:p2",
            sessionID: "01a00000-0000-7000-8000-000000000001"
        )
        let latest = try #require(ResponseBriefSource.latest(
            turns: turns,
            machineID: "synthetic-machine",
            paneID: "w1:p2",
            sessionID: "01a00000-0000-7000-8000-000000000001"
        ))

        #expect(completed.count == 2_000)
        #expect(latest == completed.last)
        #expect(latest.previousUserText == "Question 1998")
        #expect(latest.previousAssistantText == "Answer 1998")
    }

    @Test("A final aborted or tool-only conclusion does not promote earlier commentary")
    func rejectsCommentaryBeforeAbortedConclusion() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try snapshot(
            entries: """
            [
              {"type":"message","id":"u1","message":{"role":"user","content":"Question"}},
              {"type":"message","id":"commentary","message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"text","text":"Partial commentary"},{"type":"toolCall","id":"call-1","name":"read","arguments":{}}]}},
              {"type":"message","id":"tool-result","message":{"role":"toolResult","toolCallId":"call-1","toolName":"read","content":"result"}},
              {"type":"message","id":"aborted","message":{"role":"assistant","stopReason":"aborted","content":[]}}
            ]
            """
        ))

        #expect(ResponseBriefSource.completedSources(
            turns: reducer.turns,
            machineID: "synthetic-machine",
            paneID: "p1",
            sessionID: "01a00000-0000-7000-8000-000000000001"
        ).isEmpty)
    }

    @Test("Agent settlement accepts the final live multi-part message, not tool commentary")
    func liveFinalMessageAfterTools() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try snapshot(
            entries: """
            [
              {"type":"message","id":"u1","message":{"role":"user","content":"Question"}},
              {"type":"message","id":"commentary","message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"text","text":"Checking"},{"type":"toolCall","id":"call-1","name":"read","arguments":{}}]}},
              {"type":"message","id":"tool-result","message":{"role":"toolResult","toolCallId":"call-1","toolName":"read","content":"result"}}
            ]
            """,
            state: #"{"isStreaming":true}"#
        ))
        _ = reducer.apply(try envelope(1, #"{"type":"message_start","message":{"role":"assistant","id":"final-live","content":[]}}"#))
        _ = reducer.apply(try envelope(2, #"{"type":"message_end","message":{"role":"assistant","id":"final-live","stopReason":"stop","content":[{"type":"text","text":"One"},{"type":"text","text":" two"}]}}"#))
        _ = reducer.apply(try envelope(3, #"{"type":"agent_settled"}"#))

        let source = try #require(ResponseBriefSource.latest(
            turns: reducer.turns,
            machineID: "synthetic-machine",
            paneID: "p1",
            sessionID: "01a00000-0000-7000-8000-000000000001"
        ))
        #expect(source.responseID == "final-live")
        #expect(source.text == "One two")
    }

    @Test("Active or queued reducer turns never become completed brief sources")
    func rejectsActiveAndQueuedTurns() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try snapshot(
            entries: """
            [
              {"type":"message","id":"u1","message":{"role":"user","content":"First"}},
              {"type":"message","id":"a1","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"Settled"}]}},
              {"type":"message","id":"u2","message":{"role":"user","content":"Queued"}},
              {"type":"message","id":"a2","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"Projected but not settled"}]}}
            ]
            """,
            state: #"{"isStreaming":true,"working":true}"#
        ))

        let sources = ResponseBriefSource.completedSources(
            turns: reducer.turns,
            machineID: "synthetic-machine",
            paneID: "p1",
            sessionID: "01a00000-0000-7000-8000-000000000001"
        )
        #expect(sources.map(\.responseID) == ["a1"])
    }

    @Test("Length, error, aborted, and tool-use stops are ineligible")
    func rejectsUnsuccessfulStops() {
        for reason in ["length", "error", "aborted", "toolUse"] {
            let turn = PiConversationTurn(
                id: reason,
                user: .init(id: "u", text: "Question", timestamp: nil),
                items: [.assistant(.init(id: "a:text:0", text: "Not final", status: .complete, stopReason: reason))],
                isActive: false
            )
            #expect(ResponseBriefSource.completedSources(
                turns: [turn],
                machineID: "synthetic-machine",
                paneID: "p1",
                sessionID: "01a00000-0000-7000-8000-000000000001"
            ).isEmpty)
        }
    }

    @Test("A live answer without an identifier verifies continuity with its persisted entry")
    func liveToPersistedIdentity() throws {
        var live = PiConversationReducer()
        live.replace(with: try snapshot(entries: "[]", state: #"{"isStreaming":true}"#))
        _ = live.apply(try envelope(1, #"{"type":"message_end","message":{"role":"user","content":"Question","timestamp":1786536000000}}"#))
        _ = live.apply(try envelope(2, #"{"type":"message_start","message":{"role":"assistant","timestamp":1786536060000,"content":[]}}"#))
        _ = live.apply(try envelope(3, #"{"type":"message_update","assistantMessageEvent":{"type":"text_end","contentIndex":0,"content":"Exact answer"}}"#))
        _ = live.apply(try envelope(4, #"{"type":"message_end","message":{"role":"assistant","timestamp":1786536060000,"stopReason":"stop","content":[{"type":"text","text":"Exact answer"}]}}"#))
        _ = live.apply(try envelope(5, #"{"type":"agent_settled"}"#))

        let liveSource = try #require(ResponseBriefSource.latest(
            turns: live.turns,
            machineID: "synthetic-machine",
            paneID: "p1",
            sessionID: "s1"
        ))
        #expect(liveSource.responseID == "live:s1:1786536060000")
        #expect(liveSource.identity?.responseTimestamp == Date(timeIntervalSince1970: 1_786_536_060))
        #expect(liveSource.identity?.userTimestamp == Date(timeIntervalSince1970: 1_786_536_000))

        var persisted = PiConversationReducer()
        persisted.replace(with: try snapshot(entries: """
        [
          {"type":"message","id":"entry-u1","timestamp":"2026-09-01T00:00:00Z","message":{"role":"user","content":"Question","timestamp":1786536000000}},
          {"type":"message","id":"entry-a1","timestamp":"2026-09-01T00:00:01Z","message":{"role":"assistant","timestamp":1786536060000,"stopReason":"stop","content":[{"type":"text","text":"Exact answer"}]}}
        ]
        """))
        let persistedSource = try #require(ResponseBriefSource.latest(
            turns: persisted.turns,
            machineID: "synthetic-machine",
            paneID: "p1",
            sessionID: "s1"
        ))
        #expect(persistedSource.responseID == "entry-a1")
        #expect(persistedSource.identity == liveSource.identity)
        #expect(ResponseBriefIdentity.match(liveSource, persistedSource) == .verifiedContinuation)
    }

    @Test("Source identity mirrors projected timestamps and never invents them")
    func identityMirrorsProjectedTimestamps() throws {
        let responseDate = Date(timeIntervalSince1970: 1_800_000_100)
        let userDate = Date(timeIntervalSince1970: 1_800_000_000)
        let timestamped = PiConversationTurn(
            id: "turn-timestamped",
            user: PiUserMessage(id: "u1", text: "Question", timestamp: userDate),
            items: [.assistant(.init(
                id: "answer-1:text:0",
                text: "Exact answer",
                status: .complete,
                timestamp: responseDate,
                stopReason: "stop"
            ))],
            isActive: false
        )
        let timestampedSource = try #require(ResponseBriefSource.latest(
            turns: [timestamped],
            machineID: "synthetic-machine",
            paneID: "p1",
            sessionID: "s1"
        ))
        #expect(timestampedSource.identity?.responseTimestamp == responseDate)
        #expect(timestampedSource.identity?.userTimestamp == userDate)
        #expect(timestampedSource.identity?.responseTextHash == ResponseBriefIdentityEvidence.hash("Exact answer"))
        #expect(timestampedSource.identity?.userTextHash == ResponseBriefIdentityEvidence.hash("Question"))

        let undated = PiConversationTurn(
            id: "turn-undated",
            user: PiUserMessage(id: "u2", text: "Question", timestamp: nil),
            items: [.assistant(.init(
                id: "answer-2:text:0",
                text: "Exact answer",
                status: .complete,
                stopReason: "stop"
            ))],
            isActive: false
        )
        let undatedSource = try #require(ResponseBriefSource.latest(
            turns: [undated],
            machineID: "synthetic-machine",
            paneID: "p1",
            sessionID: "s1"
        ))
        #expect(undatedSource.identity?.responseTimestamp == nil)
        #expect(undatedSource.identity?.userTimestamp == nil)
        #expect(undatedSource.identity?.responseTextHash == ResponseBriefIdentityEvidence.hash("Exact answer"))
    }

    @Test("Length-aware requests carry the selection and drop superseded prompt caps")
    func lengthAwareRequestContract() throws {
        let source = makeSource(
            text: "line one\nline two",
            current: "Current question",
            previousUser: nil,
            previousAssistant: nil
        )
        let legacy = try ResponseBriefRequestBuilder.request(
            for: source,
            model: "provider/model",
            thinkingLevel: "low",
            clientRequestID: "legacy-request"
        )
        #expect(legacy.responseBriefLength == nil)
        #expect(legacy.prompt == ResponseBriefRequestBuilder.prompt)
        #expect(legacy.prompt.contains("140 words"))

        let selected = try ResponseBriefRequestBuilder.request(
            for: source,
            model: "provider/model",
            thinkingLevel: "low",
            clientRequestID: "selected-request",
            length: .long
        )
        #expect(selected.responseBriefLength == .long)
        #expect(selected.prompt == ResponseBriefRequestBuilder.lengthPrompt)
        #expect(!selected.prompt.contains("140 words"))
        #expect(!selected.prompt.contains("0-4 points"))
        #expect(!selected.prompt.contains("0-6"))
        #expect(selected.context.items == legacy.context.items)
        #expect(selected.context.source == legacy.context.source)

        let selectedData = try JSONEncoder().encode(selected)
        let selectedJSON = try #require(JSONSerialization.jsonObject(with: selectedData) as? [String: Any])
        #expect(selectedJSON["responseBriefLength"] as? String == "long")

        let legacyData = try JSONEncoder().encode(legacy)
        let legacyJSON = try #require(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        #expect(legacyJSON["responseBriefLength"] == nil)
    }

    @Test("Generic assistant requests never encode the brief-only length field")
    func genericRequestOmitsLength() throws {
        let request = AssistantRequest(
            prompt: "Synthetic question",
            profile: "contextual-question-v1",
            paneId: "w1:p1",
            scope: .init(),
            context: AssistantContext(
                source: .init(feature: "notes", instanceId: "synthetic-note"),
                items: []
            ),
            model: nil,
            thinkingLevel: nil
        )
        #expect(request.responseBriefLength == nil)

        let data = try JSONEncoder().encode(request)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["responseBriefLength"] == nil)
    }

    @Test("Capability decoding stays additive and reports length policy support")
    func capabilityLengthPolicyDecoding() throws {
        let modern = try JSONDecoder().decode(
            AssistantCapabilities.self,
            from: Data(#"{"ok":true,"profiles":["response-brief-v1"],"responseBriefs":{"version":1,"lengthPolicyVersion":2,"lengthOptions":["minimal","medium","long"],"tools":"none","oneShot":true,"maxOutputBytes":32768,"requiresParentSessionId":true}}"#.utf8)
        )
        #expect(modern.responseBriefs?.supportsLengthPolicy == true)
        #expect(modern.responseBriefs?.advertisedLengths == [.minimal, .medium, .long])
        #expect(modern.responseBriefs?.supportsEveryLengthOption == true)

        let predecessor = try JSONDecoder().decode(
            AssistantCapabilities.self,
            from: Data(#"{"ok":true,"profiles":["response-brief-v1"],"responseBriefs":{"version":1,"tools":"none","oneShot":true,"maxOutputBytes":32768,"requiresParentSessionId":true}}"#.utf8)
        )
        #expect(predecessor.responseBriefs?.supportsLengthPolicy == false)
        #expect(predecessor.responseBriefs?.advertisedLengths.isEmpty == true)
        #expect(predecessor.responseBriefs?.supportsEveryLengthOption == false)

        let oldest = try JSONDecoder().decode(
            AssistantCapabilities.self,
            from: Data(#"{"ok":true,"profiles":["response-brief-v1"]}"#.utf8)
        )
        #expect(oldest.responseBriefs == nil)
        #expect(oldest.profiles == ["response-brief-v1"])
    }

    @Test("UTF-8 chunks reconstruct multibyte source without loss")
    func multibyteChunks() throws {
        let source = String(repeating: "🪻café\r\n```swift\nlet value = 1\n```\n| A | B |\n", count: 900)
        let chunks = try ResponseBriefRequestBuilder.utf8Chunks(source, maximumBytes: 101)
        #expect(chunks.joined() == source)
        #expect(chunks.allSatisfy { $0.utf8.count <= 101 })
    }

    @Test("Encoded request matches the server item kind, label, count, and priority contract")
    func boundedConversationContext() throws {
        let source = makeSource(
            text: "line 1\r\n\nline 3",
            current: "Current",
            previousUser: "Previous",
            previousAssistant: "Previous answer"
        )
        let request = try ResponseBriefRequestBuilder.request(
            for: source,
            model: "provider/model",
            thinkingLevel: "low",
            clientRequestID: "stable-request"
        )
        let required = request.context.items.filter { $0.priority == "required" }
        let optional = request.context.items.filter { $0.priority == "optional" }

        #expect(required.map(\.text).joined() == source.text)
        #expect(required.enumerated().allSatisfy { index, item in
            item.label == "Original response part \(index + 1) of \(required.count) (concatenate verbatim in order)"
        })
        #expect(request.context.items.allSatisfy { $0.kind == "text.v1" })
        #expect(optional.map(\.id) == ["previous-user", "previous-assistant", "current-user"])
        #expect(request.context.items.count <= 16)
        #expect(request.profile == "response-brief-v1")
        #expect(request.parentSessionId == source.chat.sessionID)
        #expect(request.thinkingLevel == "low")
        #expect(request.clientRequestId == "stable-request")
        #expect(request.context.source.feature == "chat.response-brief")

        let data = try JSONEncoder().encode(request)
        #expect(data.count <= ResponseBriefLimits.maximumEnvelopeBytes)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let context = try #require(root["context"] as? [String: Any])
        let encodedItems = try #require(context["items"] as? [[String: Any]])
        #expect(encodedItems.filter { $0["priority"] as? String == "optional" }.count == 3)
        #expect(encodedItems.allSatisfy { item in
            ["text-selection.v1", "text.v1", "note.v1", "view.v1"].contains(item["kind"] as? String)
        })
    }

    @Test("An oversize half omits the whole previous exchange but keeps current user context")
    func asymmetricPreviousExchangeOmission() throws {
        let source = makeSource(
            text: "Target response",
            current: "Current question",
            previousUser: String(
                repeating: "u",
                count: ResponseBriefLimits.maximumContextItemBytes + 1
            ),
            previousAssistant: "Previous answer"
        )
        let request = try ResponseBriefRequestBuilder.request(
            for: source,
            model: nil,
            thinkingLevel: nil,
            clientRequestID: "stable-request"
        )
        let optionalIDs = request.context.items
            .filter { $0.priority == "optional" }
            .map(\.id)

        #expect(optionalIDs == ["current-user"])
        #expect(ResponseBriefRequestBuilder.optionalContextOmissionNote(for: source, request: request) == "Optional context omitted to fit the bounded request: the previous exchange. The original response remains exact.")
    }

    @Test("Optional context omission is explicit while required target remains exact")
    func optionalOmissionNote() throws {
        let source = makeSource(
            text: String(repeating: "target 🪻\n", count: 1_300),
            current: String(repeating: "current", count: 3_000),
            previousUser: "Previous",
            previousAssistant: "Previous answer"
        )
        let request = try ResponseBriefRequestBuilder.request(
            for: source,
            model: nil,
            thinkingLevel: nil,
            clientRequestID: "stable-request"
        )

        let requiredText = request.context.items
            .filter { $0.priority == "required" }
            .map(\.text)
            .joined()
        #expect(requiredText == source.text)
        #expect(ResponseBriefRequestBuilder.optionalContextOmissionNote(for: source, request: request)?.contains("current user message") == true)
    }

    @Test("Full target is rejected rather than truncated when JSON escaping exceeds envelope")
    func escapedOversize() {
        let source = makeSource(
            text: String(repeating: "\\\"", count: 24_000),
            current: nil,
            previousUser: nil,
            previousAssistant: nil
        )
        #expect(throws: ResponseBriefRequestError.sourceTooLarge) {
            try ResponseBriefRequestBuilder.request(for: source, model: nil, thinkingLevel: nil)
        }
    }

    private func makeSource(
        text: String,
        current: String?,
        previousUser: String?,
        previousAssistant: String?
    ) -> ResponseBriefSource {
        ResponseBriefSource(
            chat: .init(
                machineID: "synthetic-machine",
                paneID: "w1:p2",
                sessionID: "01a00000-0000-7000-8000-000000000001"
            ),
            responseID: "answer-2",
            text: text,
            currentUserText: current,
            previousUserText: previousUser,
            previousAssistantText: previousAssistant
        )
    }

    private func envelope(_ cursor: Int, _ eventJSON: String) throws -> PiConversationEnvelope {
        PiConversationEnvelope(
            paneID: "p1",
            sessionID: "s1",
            cursor: String(cursor),
            event: try JSONDecoder().decode(PiJSONValue.self, from: Data(eventJSON.utf8))
        )
    }

    private func snapshot(entries: String, state: String = #"{"isStreaming":false}"#) throws -> PiConversationSnapshot {
        try JSONDecoder().decode(
            PiConversationSnapshot.self,
            from: Data(
                """
                {
                  "protocol":{"name":"herdr.pi.semantic","version":1},
                  "paneId":"p1","available":true,"connected":true,
                  "session":{"id":"s1"},"state":\(state),"entries":\(entries),
                  "pendingInteractions":[],"cursor":"0","oldestCursor":"0","truncated":false
                }
                """.utf8
            )
        )
    }
}

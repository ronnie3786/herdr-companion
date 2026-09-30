import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Hosted First Mate final footers", .serialized)
@MainActor
struct FirstMateMessageFooterTests {
    private let now = HerdrTimestamp.date(from: "2030-06-14T15:25:00Z")!
    private var context: FirstMateTimestampContext {
        FirstMateTimestampContext(calendar: Calendar(identifier: .gregorian),
                                  locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    @Test("Actual actions and time align without overlap at both widths, every scale and appearance",
          arguments: [CGFloat(320), 640], HerdrFontScale.allCases)
    func geometry(width: CGFloat, scale: HerdrFontScale) async throws {
        for scheme in [ColorScheme.light, .dark] {
            for main in [true, false] {
                let message = message()
                let evidence = await measure(surface(message, main: main, feedback: state(.down), documents: !main,
                                                     bubbleWidth: FirstMateChatTranscript.bubbleMaxWidth(forWidth: width)),
                                             width: width, scale: scale, scheme: scheme)
                try assertFooter(evidence, id: message.id)
                let bubble = try #require(evidence.rects["sample:bubble"])
                #expect(bubble.maxX <= width + 1)
                let final = try #require(evidence.rects["sample:final-row"])
                #expect(final.maxY <= bubble.maxY)
                #expect(bubble.maxY - final.maxY <= 10, "No timestamp-only lower band")
                #expect(evidence.labels["sample"] == (main ? "Today · \(context.clock(now))" : context.clock(now)))
            }
        }
    }

    @Test("Saved, saving, loading, offline, failure, conflict and Copy-only states remain above the final row")
    func states() async throws {
        for main in [true, false] {
            for feedback in [nil, state(nil), state(.up), state(.down), state(.down, saving: true),
                             state(nil, writable: false), state(.down, writable: false),
                             state(.down, error: "A synthetic save failed. Reconnect and explicitly retry this rating."),
                             state(.down, error: "The rating changed in another synthetic client. Reload before retrying.", conflict: true)] {
                let evidence = await measure(surface(message(long: true), main: main, feedback: feedback,
                                                     bubbleWidth: FirstMateChatTranscript.bubbleMaxWidth(forWidth: 320)),
                                             width: 320, scale: .xxxLarge, scheme: .dark)
                try assertFooter(evidence, id: "sample")
                #expect(evidence.labels.count == 1, "The timestamp belongs to this response")
            }
        }
    }

    @Test("Main chat newly timestamps only eligible assistants; standalone retains user/ineligible times")
    func roleStatusMatrix() async throws {
        for role in ["assistant", "user", "human", "system"] {
            for status in ["done", "complete", "queued", "pending", "sending", "failed", "unconfirmed"] {
                var message = message()
                message.role = role
                message.status = status
                let eligible = FirstMateFeedbackEligibility.isEligible(message)
                for main in [true, false] {
                    let evidence = await measure(surface(message, main: main, feedback: nil), width: 420)
                    #expect((evidence.labels["sample"] != nil) == (!main || eligible))
                    #expect((evidence.rects["sample:final-row"] != nil) == eligible)
                }
            }
        }
        var blank = message()
        blank.text = " \n "
        let evidence = await measure(surface(blank, main: true, feedback: nil), width: 420)
        #expect(evidence.labels.isEmpty)
        #expect(evidence.rects["sample:final-row"] == nil)
    }

    @Test("Short bubbles hug content while long content gives the footer its actual width")
    func intrinsicSizing() async throws {
        for main in [true, false] {
            let short = await measure(surface(message(), main: main, feedback: state(nil)), width: 640)
            let long = await measure(surface(message(long: true), main: main, feedback: state(nil)), width: 640)
            let shortBubble = try #require(short.rects["sample:bubble"])
            let longBubble = try #require(long.rects["sample:bubble"])
            #expect(shortBubble.width < longBubble.width - 40)
            #expect(shortBubble.width < 500)
            let footer = try #require(long.rects["sample:final-row"])
            #expect(abs(footer.width - (longBubble.width - (main ? 18 : 26))) < 2)
        }
    }

    @Test("An older-year contextual timestamp wraps in its allocation without displacing the icons")
    func contextualWrapping() async throws {
        var message = message()
        message.createdAt = "2029-12-15T23:59:00Z"
        let evidence = await measure(surface(message, main: true, feedback: state(.down)), width: 320, scale: .xxxLarge)
        try assertFooter(evidence, id: message.id)
        let timestamp = try #require(evidence.rects["sample:timestamp"])
        #expect(timestamp.height > 20, "The contextual date should wrap rather than clip")
        #expect(evidence.labels["sample"]?.contains("2029") == true)
    }

    @Test("Mounted bubble, same-day sidebar and summary Updated labels share the clock; Updated keeps its source instant")
    func clockConsistency() async throws {
        for locale in ["en_US", "en_GB"] {
            var context = context
            context.locale = Locale(identifier: locale)
            let content = VStack {
                surface(message(), main: false, feedback: nil)
                FirstMateRowTopLine(name: "Synthetic feature", date: now)
                FirstMateLeadSummaryCard(conversations: [], now: now, open: { _ in })
            }
            .environment(\.firstMateTimestampContext, context)
            let evidence = await measure(content, width: 640, formatting: context)
            #expect(evidence.labels["sample"] == context.clock(now))
            #expect(evidence.labels["sidebar"] == context.clock(now))
            #expect(evidence.labels["updated"] == context.clock(now))
            let earlier = now.addingTimeInterval(-3600)
            let summary = await measure(FirstMateLeadSummaryCard(conversations: [], now: earlier, open: { _ in }), width: 640, formatting: context)
            #expect(summary.labels["updated"] == context.clock(earlier))
        }
    }

    @Test("Ready skims and pending skim/status content precede the same completed Copy-only footer")
    func skimFooterGeometry() async throws {
        let ready = try FirstMateSkimFixtures.message(FirstMateSkimFixtures.txnJSON)
        #expect(FirstMateSkimReader(skim: ready.skim, reply: ready.text) != nil)
        var pending = ready
        pending.skim = FirstMateSkim(status: .pending)
        for main in [true, false] {
            for message in [ready, pending] {
                let evidence = await measure(
                    surface(message, main: main, feedback: nil,
                            bubbleWidth: FirstMateChatTranscript.bubbleMaxWidth(forWidth: 320))
                        .environment(\.skimDisplayState, SkimDisplayState()),
                    width: 320, scale: .xxxLarge
                )
                try assertFooter(evidence, id: message.id)
                #expect(evidence.labels.count == 1)
            }
        }
        // Clipboard and VoiceOver actions belong to the interactive UI runner;
        // an offscreen unit host does not materialize SwiftUI's AX graph.
    }

    @Test("Synthetic before/after references and both real surfaces render at narrow/default widths in light/dark")
    func syntheticRenders() async throws {
        for main in [true, false] {
            for width in [CGFloat(320), 640] {
                for scheme in [ColorScheme.light, .dark] {
                    for scale in [HerdrFontScale.medium, .xxxLarge] {
                        let name = "issue-126-\(main ? "main" : "standalone")-\(Int(width))-\(scheme)-\(scale.rawValue)"
                        _ = try await HerdrRenderHarness.render("\(name)-after.png", size: CGSize(width: width, height: 1200)) {
                            surface(message(long: true), main: main, feedback: state(.down), documents: !main,
                                    bubbleWidth: FirstMateChatTranscript.bubbleMaxWidth(forWidth: width))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .background(FirstMatePalette(scheme: scheme).background)
                                .environment(\.colorScheme, scheme)
                                .environment(\.herdrFontScale, scale)
                                .environment(\.firstMateTimestampContext, context)
                                .environment(\.firstMateTranscriptNow, now)
                        }
                    }
                }
            }
        }
        for main in [true, false] {
            _ = try await HerdrRenderHarness.render("issue-126-\(main ? "main" : "standalone")-short-copy-only-after.png", size: CGSize(width: 640, height: 220)) {
                surface(message(), main: main, feedback: nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(FirstMatePalette(scheme: .dark).background)
                    .environment(\.firstMateTimestampContext, context)
                    .environment(\.firstMateTranscriptNow, now)
            }
        }
        // Synthetic reconstructions of the previous presentation, not captured conversations.
        _ = try await HerdrRenderHarness.render("issue-126-main-before-reference.png", size: CGSize(width: 420, height: 180)) {
            VStack(alignment: .leading, spacing: 6) {
                Text("A completed synthetic answer.")
                HStack { Image(systemName: "hand.thumbsup"); Image(systemName: "hand.thumbsdown"); Image(systemName: "doc.on.doc") }
            }
            .padding(13)
            .background(HerdrTheme.inkFill(0.06), in: .rect(cornerRadius: 17))
            .padding(16)
        }
        _ = try await HerdrRenderHarness.render("issue-126-standalone-before-reference.png", size: CGSize(width: 420, height: 180)) {
            VStack(alignment: .leading, spacing: 6) {
                Text("A completed synthetic answer.")
                HStack { Image(systemName: "hand.thumbsup"); Image(systemName: "hand.thumbsdown"); Image(systemName: "doc.on.doc") }
                HStack { Spacer(); Text("15:25") }
            }
            .padding(13)
            .background(HerdrTheme.inkFill(0.06), in: .rect(cornerRadius: 17))
            .padding(16)
        }
    }

    private func message(long: Bool = false) -> FirstMateMessage {
        FirstMateMessage(id: "sample", featureID: "synthetic-feature", role: "assistant",
                         text: long ? String(repeating: "A synthetic completed response with readable details and a next step. ", count: 5) : "Done.",
                         status: "done", createdAt: "2030-06-14T15:25:00Z")
    }

    private func state(_ rating: FirstMateFeedbackRating?, saving: Bool = false, writable: Bool = true,
                       error: String? = nil, conflict: Bool = false) -> FirstMateResponseFeedbackPresentation {
        .init(rating: rating, isSaving: saving, isWritable: writable, savedReasonCount: rating == .down ? 100 : 0,
              hasSavedComment: rating == .down, saveErrorMessage: error, hasConflict: conflict)
    }

    @ViewBuilder private func surface(_ message: FirstMateMessage, main: Bool,
                                      feedback: FirstMateResponseFeedbackPresentation?, documents: Bool = false,
                                      bubbleWidth: CGFloat = FirstMateChatTranscript.bubbleMaxWidth(forWidth: 640)) -> some View {
        if main {
            FirstMateMessageView(message: message, feedback: feedback)
        } else {
            FirstMateChatBubbleRow(
                row: .init(message: message, speaker: message.role == "user" || message.role == "human" ? .user : .firstMate,
                           isFirstInGroup: true, isLastInGroup: true),
                agent: nil,
                fileCards: documents ? [.init(document: .init(id: "synthetic-doc", featureID: "synthetic-feature",
                                                             title: "Synthetic review document", mediaType: "text/markdown",
                                                             contentHash: "synthetic-hash", createdAt: message.createdAt), from: "Sample crew")] : [],
                maxBubbleWidth: bubbleWidth, feedback: feedback, feedbackActions: .init(), openDocuments: {}
            )
            .padding(.horizontal, 16)
        }
    }

    private func assertFooter(_ evidence: Evidence, id: String) throws {
        let final = try #require(evidence.rects["\(id):final-row"])
        let actions = try #require(evidence.rects["\(id):actions"])
        let timestamp = try #require(evidence.rects["\(id):timestamp"])
        let content = try #require(evidence.rects["\(id):content"])
        #expect(final.minY >= content.maxY - 1)
        #expect(abs(actions.midY - timestamp.midY) < 1)
        #expect(actions.maxX + 7 <= timestamp.minX)
        #expect(timestamp.maxX <= final.maxX + 1)
        #expect(timestamp.minY >= final.minY - 1)
        #expect(timestamp.maxY <= final.maxY + 1)
        #expect(actions.height >= HerdrTheme.minHitTarget)
        for part in ["secondary", "documents"] {
            if let secondary = evidence.rects["\(id):\(part)"] {
                #expect(secondary.maxY <= final.minY + 1)
            }
        }
    }

    private struct Evidence {
        var rects: [String: CGRect] = [:]
        var labels: [String: String] = [:]
    }

    private func measure(_ view: some View, width: CGFloat, scale: HerdrFontScale = .medium,
                         scheme: ColorScheme = .dark, formatting: FirstMateTimestampContext? = nil) async -> Evidence {
        var evidence = Evidence()
        let hosting = NSHostingView(rootView: view
            .environment(\.herdrFontScale, scale)
            .environment(\.colorScheme, scheme)
            .environment(\.firstMateTranscriptNow, now)
            .environment(\.firstMateTimestampContext, formatting ?? context)
            .frame(width: width)
            .backgroundPreferenceValue(FirstMateFooterLayoutKey.self) { anchors in
                GeometryReader { proxy in
                    Color.clear.onAppear { evidence.rects = anchors.mapValues { proxy[$0] } }
                }
            }
            .onPreferenceChange(FirstMateClockLabelKey.self) { evidence.labels = $0 }
        )
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 1200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 1200)
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()
        window.contentView = nil
        return evidence
    }
}

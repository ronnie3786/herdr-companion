import SwiftUI

struct FirstMateChatTranscript: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let conversation: FirstMateConversation?
    let catalog: FirstMateMentionCatalog
    let canControl: Bool
    var scrollToLatestRequest = 0
    @Binding var followsLatest: Bool
    @Binding var readLayout: FirstMateMobileTranscriptPolicy.ReadLayout?
    @Binding var expandedReplies: Set<String>
    let openInfo: (FirstMateInspector) -> Void
    let sendReply: (String) -> Bool
    let presentationChanged: (String, Bool) -> Void
    let fleet: FirstMateMobileFleetStore
    let ownerMachineID: String
    let openFeature: (FirstMateFeatureTarget) -> Void
    var canRate = false
    @State private var feedbackRequest: FirstMateMobileFeedbackRequest?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var readout: FirstMateMobileReadoutRequest?
    @State private var positioned = false
    @State private var diagnostics = "Metrics"
    @State private var skimState = SkimReadingState()
    @State private var choices: [String: String] = [:]
    @State private var containerWidth: CGFloat = 402

    private var messages: [FirstMateMessage] { FirstMateTranscriptLayout.orderedMessages(store: store, snapshot: snapshot) }
    private var typing: Bool {
        FirstMateTranscriptLayout.isTyping(messages: messages,
            isSending: FirstMateTranscriptLayout.isAwaitingReply(store: store, snapshot: snapshot),
            isWorkingOnReply: conversation?.isWorkingOnReply == true)
    }

    var body: some View {
        let feedbackContext = store.operationContext
        let messages = messages
        let readoutConversations = fleet.conversations.filter { $0.machineID == ownerMachineID }
        let typing = !FirstMateMobileTranscriptPolicy.isClosed(snapshot) && typing
        let rows = FirstMateTranscriptLayout.rows(for: messages, typing: typing,
            pendingDecisionMessageID: snapshot.pendingDecisionMessageID, now: .now, calendar: .current)
        let expandedIDs = expandedReplies
        let displayedIDs = FirstMateMobileTranscriptPolicy.displayedServerIDs(rows: rows,
            expanded: expandedIDs, featureID: snapshot.feature.id)
        let files = FirstMateMobileTranscriptPolicy.fileCards(messages: messages, snapshot: snapshot)
        let links = FirstMateMobileTranscriptPolicy.linkCards(messages: messages, snapshot: snapshot)
        let replies = FirstMateMobileTranscriptPolicy.replies(messages: messages, snapshot: snapshot,
            needsYou: conversation?.hudStatus.needsYou == true, isTyping: typing)
        // No GeometryReader: the scroll view must be the bars' direct neighbor
        // so the system scroll-edge effect blurs content under them.
        let width = min(((min(containerWidth, 720) - 32) * 0.82).rounded(), 560)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if rows.isEmpty {
                        Text("Your First Mate is here. Share the outcome you want and any constraints.")
                            .herdrFont(.body).foregroundStyle(HerdrTheme.secondaryText)
                            .padding(.vertical, 24)
                    }
                    // Measure changing rows in small batches. Individual lazy
                    // row estimates can cycle when Send also shrinks the composer.
                    // Older batches still load on demand for long conversations.
                    ForEach(rowBatches(rows)) { batch in
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(batch.rows) { row in
                                if let day = row.dayLabel {
                                    HStack(spacing: 4) {
                                        Text(day)
                                        if let date = HerdrTimestamp.date(from: row.message.createdAt) { Text(FirstMateChatTime.clock(for: date, calendar: .current)) }
                                    }
                                    .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(HerdrTheme.codeFill, in: .capsule)
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                                }
                                FirstMateChatBubble(row: row, snapshot: snapshot, maximumWidth: width,
                                    skimState: skimState, catalog: catalog,
                                    replies: row.id == rows.last?.id ? replies : [], choice: choices[row.id], canReply: canControl,
                                    sendReply: { reply in if sendReply(reply) { choices[row.id] = reply } },
                                    presentationChanged: presentationChanged, readoutConversations: readoutConversations,
                                    showReadout: { readout = .capture($0, fleet: fleet) },
                                    feedback: store.feedback(for: snapshot.feature.id, messageID: row.message.id),
                                    rate: feedbackAction(row.message))
                                    .padding(.top, row.isFirstInGroup ? 8 : 0)
                                    .id(row.id)
                                if !row.additionalReplies.isEmpty {
                                    DisclosureGroup("Additional response from this turn", isExpanded: additionalRepliesExpanded(row.id)) {
                                        ForEach(row.additionalReplies) { message in
                                            FirstMateChatBubble(row: .init(message: message, speaker: FirstMateTranscriptLayout.speaker(for: message),
                                                isFirstInGroup: true, isLastInGroup: true), snapshot: snapshot, maximumWidth: width,
                                                skimState: skimState, catalog: catalog, sendReply: { _ in }, presentationChanged: presentationChanged, readoutConversations: readoutConversations,
                                                showReadout: { readout = .capture($0, fleet: fleet) },
                                                feedback: store.feedback(for: snapshot.feature.id, messageID: message.id),
                                                rate: feedbackAction(message))
                                            resources(files: files[message.id] ?? [], links: links[message.id] ?? [], width: width)
                                        }
                                    }
                                    .herdrFont(.caption).tint(HerdrTheme.accent).frame(maxWidth: width)
                                }
                                resources(files: files[row.id] ?? [], links: links[row.id] ?? [], width: width)
                            }
                        }
                    }
                    if typing {
                        HStack(spacing: 5) {
                            ForEach(0..<3) { _ in Circle().fill(HerdrTheme.secondaryText).frame(width: 6, height: 6) }
                        }
                        .padding(14).background(HerdrTheme.codeFill, in: .rect(cornerRadius: 18))
                        .phaseAnimator(reduceMotion ? [false] : [false, true]) { view, pulse in
                            view.opacity(pulse ? 1 : 0.75)
                        } animation: { _ in .easeInOut(duration: 1.1) }
                        .accessibilityElement(children: .ignore).accessibilityLabel("First Mate is working on a reply")
                        .accessibilityIdentifier("first-mate-typing")
                    }
                    if let error = store.error {
                        Text(error).herdrFont(.footnote).foregroundStyle(HerdrTheme.warning)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("first-mate-chat-error")
                    }
                    Color.clear.frame(height: 1).id("first-mate-chat-end")
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: 720).frame(maxWidth: .infinity)
            }
            .herdrEdgeFade()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
            .defaultScrollAnchor(.bottom)
            // Short transcripts remain fully visible without synthetic top
            // insets competing with explicit bottom-scroll requests.
            .defaultScrollAnchor(.topLeading, for: .alignment)
            .defaultScrollAnchor(followsLatest ? .bottom : nil, for: .sizeChanges)
            .task {
                guard !positioned else { return }
                positioned = true
                await Task.yield()
                proxy.scrollTo("first-mate-chat-end", anchor: .bottom)
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: FirstMateMobileTranscriptPolicy.ReadLayout.self) { geometry in
                observeLayout(geometry, messages: messages, displayedIDs: displayedIDs, expandedIDs: expandedIDs)
            } action: { _, layout in
                followsLatest = layout.followsLatest
                readLayout = layout
            }
            .onChange(of: messages) { _, _ in
                if followsLatest { proxy.scrollTo("first-mate-chat-end", anchor: .bottom) }
            }
            .onChange(of: typing) { _, _ in
                if followsLatest { proxy.scrollTo("first-mate-chat-end", anchor: .bottom) }
            }
            .onChange(of: scrollToLatestRequest) { _, _ in
                proxy.scrollTo("first-mate-chat-end", anchor: .bottom)
            }
            .onChange(of: skimState.scrollRequest) { _, request in
                guard let request else { return }
                followsLatest = false
                proxy.revealSkimTarget(request)
            }
            .accessibilityIdentifier("first-mate-conversation")
            .popover(item: $readout) { request in
                FirstMateFeatureReadout(conversation: request.conversation) {
                    guard request.isCurrent(in: fleet) else { readout = nil; return }
                    readout = nil; openFeature(request.target)
                }.presentationCompactAdaptation(.popover)
            }
            .sheet(item: $feedbackRequest) { request in FirstMateMobileFeedbackEditor(request: request, fleet: fleet) }
            .onChange(of: feedbackRequest != nil) { _, shown in presentationChanged("feedback", shown) }
            .task(id: feedbackContext) {
                if feedbackContext.matchesFeature(snapshot.feature.id), store.feedbackSupported { _ = await store.loadFeedback(expectedContext: feedbackContext) }
            }
            .onChange(of: readout != nil) { _, shown in presentationChanged("readout", shown) }
            .onDisappear { readLayout = nil; presentationChanged("readout", false); presentationChanged("feedback", false) }
            #if DEBUG
            .overlay(alignment: .topTrailing) {
                if FirstMateTranscriptPerformanceProbe.enabled {
                    Button(diagnostics) { diagnostics = FirstMateTranscriptPerformanceProbe.summary }
                        .font(.caption2).padding(8).background(HerdrTheme.base)
                        .accessibilityIdentifier("first-mate-transcript-metrics")
                        .padding(.top, 80) // Keep the probe clear of the floating chat bar.
                }
            }
            #endif
        }
    }

    private struct RowBatch: Identifiable {
        let rows: ArraySlice<FirstMateTranscriptLayout.Row>
        var id: String { rows[rows.startIndex].id }
    }

    private func rowBatches(_ rows: [FirstMateTranscriptLayout.Row]) -> [RowBatch] {
        stride(from: 0, to: rows.count, by: 16).map { start in
            RowBatch(rows: rows[start..<min(start + 16, rows.count)])
        }
    }

    private func feedbackAction(_ message: FirstMateMessage) -> ((FirstMateFeedbackRating?) -> Void)? {
        let target = FirstMateFeatureTarget(machineID: ownerMachineID, featureID: snapshot.feature.id)
        guard canRate, store.feedbackSupported, store.controlAvailable,
              let request = FirstMateMobileFeedbackRequest.capture(message, target: target, store: store, fleet: fleet) else { return nil }
        return { rating in
            guard request.isCurrent(fleet: fleet), store.controlAvailable else { return }
            if rating == .up {
                Task {
                    guard request.isCurrent(fleet: fleet), store.controlAvailable else { return }
                    if !(await store.rateFeedback(.up, messageID: message.id, expectedContext: request.context)), request.isCurrent(fleet: fleet) {
                        feedbackRequest = request
                    }
                }
            } else {
                var editRequest = request; editRequest.requestedRating = rating
                feedbackRequest = editRequest
            }
        }
    }

    private func additionalRepliesExpanded(_ id: String) -> Binding<Bool> {
        Binding(get: { expandedReplies.contains(id) }, set: { expanded in
            if expanded { expandedReplies.insert(id) } else { expandedReplies.remove(id) }
            readLayout = nil
        })
    }

    private func observeLayout(_ geometry: ScrollGeometry, messages: [FirstMateMessage], displayedIDs: Set<String>, expandedIDs: Set<String>) -> FirstMateMobileTranscriptPolicy.ReadLayout {
        // containerSize excludes both bar insets. The top bar's inset shifts the
        // offset (it rests at -top), so add it back before comparing with the end.
        // Content/projection changes require a new observation even at equal height.
        .init(storeID: ObjectIdentifier(store), lifecycle: store.lifecycle, messages: messages,
              displayedServerIDs: displayedIDs, expandedReplies: expandedIDs,
              followsLatest: FirstMateMobileTranscriptPolicy.nearBottom(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                viewport: geometry.containerSize.height, content: geometry.contentSize.height, bottomInset: 0))
    }

    @ViewBuilder
    private func resources(files: [FirstMateDocument], links: [FirstMateLink], width: CGFloat) -> some View {
        ForEach(files) { document in
            Button { openInfo(.documents) } label: {
                card(title: document.title, subtitle: documentSource(document), symbol: "doc.text")
            }
            .buttonStyle(.plain).frame(maxWidth: width)
            .accessibilityIdentifier("first-mate-file-\(document.id)")
        }
        ForEach(links) { link in
            if let url = link.destination {
                Link(destination: url) { card(title: link.title, subtitle: link.hostLabel ?? "Saved pull request", symbol: "arrow.up.right.square") }
                    .frame(maxWidth: width).accessibilityIdentifier("first-mate-link-\(link.id)")
            }
        }
    }

    /// "From Device QA", as on the Mac, naming the agent that produced it.
    private func documentSource(_ document: FirstMateDocument) -> String {
        guard let id = document.assignmentID else { return "Saved document" }
        let agent = snapshot.assignments.first { $0.id == id && $0.featureID == snapshot.feature.id }
        return agent.map { "From \($0.title)" } ?? "From an agent"
    }

    private func card(title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(HerdrTheme.accent)
                .frame(width: 38, height: 38)
                .background(HerdrTheme.accent.opacity(0.12), in: .rect(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(HerdrTheme.accent.opacity(0.22)) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).herdrFont(.body, weight: .semibold).foregroundStyle(HerdrTheme.primaryText)
                Text(subtitle).herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 44).frame(maxWidth: .infinity, alignment: .leading)
        .background(HerdrTheme.codeFill, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(HerdrTheme.subtleSeparator))
    }
}

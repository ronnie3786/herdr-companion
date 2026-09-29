import SwiftUI

struct FirstMateChatTranscript: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let conversation: FirstMateConversation?
    let catalog: FirstMateMentionCatalog
    let canControl: Bool
    @Binding var followsLatest: Bool
    let openInfo: (FirstMateInspector) -> Void
    let sendReply: (String) -> Bool
    let presentationChanged: (String, Bool) -> Void
    let fleet: FirstMateMobileFleetStore
    let ownerMachineID: String
    let openFeature: (FirstMateFeatureTarget) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var readout: FirstMateMobileReadoutRequest?
    @State private var positioned = false
    @State private var diagnostics = "Metrics"
    @State private var skimState = SkimReadingState()
    @State private var choices: [String: String] = [:]

    private var messages: [FirstMateMessage] { FirstMateTranscriptLayout.orderedMessages(store: store, snapshot: snapshot) }
    private var typing: Bool {
        FirstMateTranscriptLayout.isTyping(messages: messages,
            isSending: FirstMateTranscriptLayout.isAwaitingReply(store: store, snapshot: snapshot),
            isWorkingOnReply: conversation?.isWorkingOnReply == true)
    }

    var body: some View {
        let messages = messages
        let readoutConversations = fleet.conversations.filter { $0.machineID == ownerMachineID }
        let typing = !FirstMateMobileTranscriptPolicy.isClosed(snapshot) && typing
        let rows = FirstMateTranscriptLayout.rows(for: messages, typing: typing,
            pendingDecisionMessageID: snapshot.pendingDecisionMessageID, now: .now, calendar: .current)
        let files = FirstMateMobileTranscriptPolicy.fileCards(messages: messages, snapshot: snapshot)
        let links = FirstMateMobileTranscriptPolicy.linkCards(messages: messages, snapshot: snapshot)
        let replies = FirstMateMobileTranscriptPolicy.replies(messages: messages, snapshot: snapshot,
            needsYou: conversation?.hudStatus.needsYou == true, isTyping: typing)
        GeometryReader { geometry in
            let width = min(((min(geometry.size.width, 720) - 32) * 0.82).rounded(), 560)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if rows.isEmpty {
                            Text("Your First Mate is here. Share the outcome you want and any constraints.")
                                .herdrFont(.body).foregroundStyle(HerdrTheme.secondaryText)
                                .padding(.vertical, 24)
                        }
                        ForEach(rows) { row in
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
                                showReadout: { readout = .capture($0, fleet: fleet) })
                                .padding(.top, row.isFirstInGroup ? 8 : 0)
                                .id(row.id)
                            if !row.additionalReplies.isEmpty {
                                DisclosureGroup("Additional response from this turn") {
                                    ForEach(row.additionalReplies) { message in
                                        FirstMateChatBubble(row: .init(message: message, speaker: FirstMateTranscriptLayout.speaker(for: message),
                                            isFirstInGroup: true, isLastInGroup: true), snapshot: snapshot, maximumWidth: width,
                                            skimState: skimState, catalog: catalog, sendReply: { _ in }, presentationChanged: presentationChanged, readoutConversations: readoutConversations,
                                            showReadout: { readout = .capture($0, fleet: fleet) })
                                    }
                                }
                                .herdrFont(.caption).tint(HerdrTheme.accent).frame(maxWidth: width)
                            }
                            ForEach(files[row.id] ?? []) { document in
                                Button { openInfo(.documents) } label: {
                                    card(title: document.title, subtitle: document.assignmentID == nil ? "Saved document" : "From Agent", symbol: "doc.text")
                                }
                                .buttonStyle(.plain).frame(maxWidth: width)
                                .accessibilityIdentifier("first-mate-file-\(document.id)")
                            }
                            ForEach(links[row.id] ?? []) { link in
                                if let url = link.destination {
                                    Link(destination: url) { card(title: link.title, subtitle: link.hostLabel ?? "Saved pull request", symbol: "arrow.up.right.square") }
                                        .frame(maxWidth: width).accessibilityIdentifier("first-mate-link-\(link.id)")
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
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(followsLatest ? .bottom : nil, for: .sizeChanges)
                .task {
                    guard !positioned else { return }
                    positioned = true
                    await Task.yield()
                    proxy.scrollTo("first-mate-chat-end", anchor: .bottom)
                }
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    FirstMateMobileTranscriptPolicy.nearBottom(offset: geometry.contentOffset.y,
                        viewport: geometry.containerSize.height, content: geometry.contentSize.height, bottomInset: geometry.contentInsets.bottom)
                } action: { _, latest in followsLatest = latest }
                .onChange(of: messages) { _, _ in
                    if followsLatest { proxy.scrollTo("first-mate-chat-end", anchor: .bottom) }
                }
                .onChange(of: typing) { _, _ in
                    if followsLatest { proxy.scrollTo("first-mate-chat-end", anchor: .bottom) }
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
                .onChange(of: readout != nil) { _, shown in presentationChanged("readout", shown) }
                .onDisappear { presentationChanged("readout", false) }
                #if DEBUG
                .overlay(alignment: .topTrailing) {
                    if FirstMateTranscriptPerformanceProbe.enabled {
                        Button(diagnostics) { diagnostics = FirstMateTranscriptPerformanceProbe.summary }
                            .font(.caption2).padding(8).background(HerdrTheme.base)
                            .accessibilityIdentifier("first-mate-transcript-metrics")
                    }
                }
                #endif
            }
        }
    }

    private func card(title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(HerdrTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).herdrFont(.body, weight: .semibold).foregroundStyle(HerdrTheme.primaryText)
                Text(subtitle).herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(14).frame(minHeight: 44).frame(maxWidth: .infinity, alignment: .leading)
        .background(HerdrTheme.codeFill, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(HerdrTheme.subtleSeparator))
    }
}

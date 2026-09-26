import SwiftUI

struct FirstMateChatView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let canControl: Bool
    let openInspector: (FirstMateInspector) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var followsLatest = true
    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }
    private var featureIsClosed: Bool { ["completed", "cancelled"].contains(snapshot.feature.status) }
    private var messages: [FirstMateMessage] { snapshot.messages.filter(\.isConversation) }

    var body: some View {
        VStack(spacing: 0) {
            resourceShortcuts.padding(.horizontal, 20).padding(.vertical, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        featureHeading
                        if let error = store.error {
                            FirstMateNoticeView(title: "Couldn't update this feature", message: error, symbol: "exclamationmark.triangle")
                        }
                        if messages.isEmpty {
                            FirstMateNoticeView(title: "Your First Mate is here", message: "Share the outcome you want and any constraints. We'll shape the plan together.", symbol: "sailboat")
                        }
                        ForEach(messages) { message in FirstMateMessageView(message: message) }
                        Color.clear.frame(height: 1).id("first-mate-chat-end")
                    }
                    .padding(20)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.top, for: .alignment)
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 70
                } action: { _, nearBottom in followsLatest = nearBottom }
                .onChange(of: snapshot.messages.last?.id) { _, _ in
                    if followsLatest { proxy.scrollTo("first-mate-chat-end", anchor: .bottom) }
                }
                .accessibilityIdentifier("first-mate-conversation")
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        checkpointStatus
                        if !featureIsClosed {
                            FirstMateComposerView(store: store, featureStatus: snapshot.feature.status, canControl: canControl)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                    .background(.bar)
                }
            }
        }
    }

    private var featureHeading: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                FirstMateStatusLabel(status: snapshot.feature.status)
                Spacer(minLength: 10)
                if let ticket = snapshot.feature.workItemID {
                    Text(ticket).font(.caption.weight(.medium)).foregroundStyle(palette.secondaryText)
                }
            }
            Text(snapshot.feature.title).font(.title2.weight(.bold)).foregroundStyle(palette.text)
                .accessibilityAddTraits(.isHeader)
            if let visit = snapshot.currentVisit {
                Label(visit.title, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline).foregroundStyle(palette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resourceShortcuts: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                shortcut(.workflow, title: "Workflow")
                shortcut(.agents, title: "Agents · \(snapshot.assignments.count)")
                shortcut(.documents, title: "Docs · \(snapshot.documents.count)")
                shortcut(.overview, title: "Overview")
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.trailing, 1)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func shortcut(_ tab: FirstMateInspector, title: String) -> some View {
        Button { openInspector(tab) } label: {
            Label(title, systemImage: tab.symbol)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(palette.surface, in: .capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.accent)
        .accessibilityIdentifier("first-mate-open-\(tab.rawValue.lowercased())")
    }

    @ViewBuilder private var checkpointStatus: some View {
        if featureIsClosed {
            statusLine("Feature closed. Your conversation and evidence are saved.", symbol: "archivebox")
        } else if !canControl {
            statusLine("Reconnect to send. Your draft stays here.", symbol: "wifi.exclamationmark")
        } else if snapshot.feature.status == "awaiting_direction" {
            statusLine(snapshot.currentVisit?.status == "completed" ? "Stage complete. Tell First Mate what comes next." : "Your direction is needed before work continues.", symbol: "hand.raised")
        } else if snapshot.feature.status == "paused" {
            statusLine("Work is paused. You can still talk with First Mate.", symbol: "pause.circle")
        } else if snapshot.feature.status == "blocked" {
            statusLine("First Mate needs your help. Tell it how to proceed.", symbol: "exclamationmark.bubble")
        } else if ["running", "coordinating", "recovering"].contains(snapshot.feature.status) {
            statusLine("Work continues in the background. Ask anything here.", symbol: "waveform.path")
        }
    }

    private func statusLine(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("first-mate-checkpoint-status")
    }
}

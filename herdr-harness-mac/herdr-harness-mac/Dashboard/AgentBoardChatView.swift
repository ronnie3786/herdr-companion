import SwiftUI

struct AgentBoardChatView: View {
    @Bindable var state: AgentBoardColumnState
    let snapshot: FirstMateSnapshot
    let openFullView: () -> Void

    var body: some View {
        let timeline = AgentBoardTimelineItem.items(in: snapshot)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if timeline.isEmpty {
                        Text("Give First Mate your direction to start the conversation.")
                            .herdrFont(.body)
                            .foregroundStyle(HerdrTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(timeline) { item in
                        switch item {
                        case .message(let message):
                            AgentBoardMessageView(message: message, openFullView: openFullView)
                        case .event(let event):
                            Text(event.summary)
                                .herdrFont(.caption)
                                .foregroundStyle(HerdrTheme.muted)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 2)
                                .textSelection(.enabled)
                        }
                    }
                    Color.clear.frame(height: 1).id("agent-board-chat-end")
                }
                .padding(16)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
            } action: { _, nearBottom in
                state.followsLatest = nearBottom
            }
            .onChange(of: snapshot.messages) { _, _ in
                if state.followsLatest { proxy.scrollTo("agent-board-chat-end", anchor: .bottom) }
            }
            .onChange(of: snapshot.events.last?.id) { _, _ in
                if state.followsLatest { proxy.scrollTo("agent-board-chat-end", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !state.followsLatest {
                    Button("Latest", systemImage: "arrow.down") {
                        state.followsLatest = true
                        proxy.scrollTo("agent-board-chat-end", anchor: .bottom)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(10)
                    .accessibilityLabel("Scroll to latest message in \(snapshot.feature.title)")
                }
            }
        }
    }
}

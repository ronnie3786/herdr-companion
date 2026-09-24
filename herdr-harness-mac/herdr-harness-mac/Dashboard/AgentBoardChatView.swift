import SwiftUI

struct AgentBoardChatView: View {
    let content: AgentBoardContent
    let openFullView: () -> Void
    /// Local so scrolling never invalidates the rest of the column.
    @State private var followsLatest = true

    private static let endID = "agent-board-chat-end"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if content.earlierMessageCount > 0 {
                        Button(action: openFullView) {
                            Text("\(content.earlierMessageCount) earlier message\(content.earlierMessageCount == 1 ? "" : "s") · Open full conversation")
                                .herdrFont(.subheadline)
                                .foregroundStyle(HerdrTheme.accent)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                    if content.timeline.isEmpty {
                        Text("No messages yet. Give First Mate your direction below.")
                            .herdrFont(.callout)
                            .foregroundStyle(HerdrTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(content.timeline) { row in
                        switch row {
                        case .message(let message):
                            AgentBoardMessageView(message: message, openFullView: openFullView)
                        case .note(let note):
                            AgentBoardNoteView(note: note)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.endID)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
            } action: { _, nearBottom in
                if followsLatest != nearBottom { followsLatest = nearBottom }
            }
            .onChange(of: content.timeline.last?.id) { _, _ in
                if followsLatest { proxy.scrollTo(Self.endID, anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest {
                    Button {
                        followsLatest = true
                        proxy.scrollTo(Self.endID, anchor: .bottom)
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                            .herdrFont(.subheadline)
                            .foregroundStyle(HerdrTheme.text)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(HerdrTheme.surface, in: .capsule)
                            .overlay { Capsule().stroke(HerdrTheme.separator) }
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .accessibilityLabel("Scroll to the latest message")
                }
            }
        }
    }
}

private struct AgentBoardNoteView: View {
    let note: AgentBoardContent.NoteRow

    var body: some View {
        Text(note.count > 1 ? "\(note.text) · \(note.count) updates" : note.text)
            .herdrFont(.subheadline)
            .foregroundStyle(HerdrTheme.muted)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .help(note.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
    }
}

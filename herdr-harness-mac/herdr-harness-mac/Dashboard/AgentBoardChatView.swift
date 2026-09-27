import SwiftUI

struct AgentBoardChatView: View {
    let content: AgentBoardContent
    let openFullView: () -> Void
    /// Local so scrolling never invalidates the rest of the column.
    @State private var followsLatest = true
    @State private var skimState = SkimDisplayState()

    private static let endID = "agent-board-chat-end"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if content.earlierMessageCount > 0 {
                        Button(action: openFullView) {
                            Text("\(content.earlierMessageCount) earlier message\(content.earlierMessageCount == 1 ? "" : "s") · Open full conversation")
                                .herdrFont(size: HerdrTheme.TextSize.caption)
                                .foregroundStyle(HerdrTheme.accent)
                                .frame(maxWidth: .infinity, minHeight: HerdrTheme.minHitTarget)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    if content.timeline.isEmpty {
                        Text("No messages yet. Give First Mate your direction below.")
                            .herdrFont(size: HerdrTheme.TextSize.small)
                            .foregroundStyle(HerdrTheme.tertiaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(content.timeline) { message in
                        AgentBoardMessageView(message: message, openFullView: openFullView)
                    }
                    Color.clear.frame(height: 1).id(Self.endID)
                }
                .environment(\.skimDisplayState, skimState)
                .environment(\.skimScrollTo) { id in proxy.scrollTo(id, anchor: .center) }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 12)
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
                        // Opaque, no blur or shadow: it floats over a scrolling list.
                        Label("Latest", systemImage: "arrow.down")
                            .labelStyle(DashboardInlineLabelStyle(spacing: 4))
                            .herdrFont(size: HerdrTheme.TextSize.small)
                            .foregroundStyle(HerdrTheme.secondaryText)
                            .padding(.horizontal, 9)
                            .frame(height: HerdrTheme.ControlHeight.small)
                            .background(HerdrTheme.inkSolid(0.13), in: .rect(cornerRadius: HerdrTheme.Radius.control))
                            .overlay {
                                RoundedRectangle(cornerRadius: HerdrTheme.Radius.control).strokeBorder(HerdrTheme.strongOutline)
                            }
                            .frame(minHeight: HerdrTheme.minHitTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .accessibilityLabel("Scroll to the latest message")
                }
            }
        }
    }
}

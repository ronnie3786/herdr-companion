import SwiftUI

/// The chat column's 60 pt header: avatar, name, a status subtitle, and the
/// inspector toggle. Empty space drags the window, like a title bar.
struct FirstMateChatHeader: View {
    let session: FirstMateChatWindowSession
    let inspectorVisible: Bool
    let toggleInspector: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .herdrFont(size: 14.5, weight: .semibold)
                    .tracking(-0.15)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)
                subtitle
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            FirstMateInspectorToggle(isOpen: inspectorVisible, action: toggleInspector)
        }
        .padding(.leading, 22)
        .padding(.trailing, 14)
        .frame(height: FirstMateChatWindowLayout.headerHeight)
        .frame(maxWidth: .infinity)
        .background { HerdrWindowDragArea() }
        .herdrHairline(.bottom)
    }

    private var conversation: FirstMateConversation? { session.selectedConversation }

    @ViewBuilder private var avatar: some View {
        switch session.selection {
        case .lead:
            FirstMateFaceOrb(size: 38)
        case .feature(let id):
            FirstMateEmojiDisc(emoji: conversation?.emoji ?? FirstMateDefaultEmoji.emoji(for: id.featureID), size: 38)
        }
    }

    private var title: String {
        switch session.selection {
        case .lead: "My First Mate"
        case .feature: conversation?.title ?? session.selectedSnapshot?.feature.title ?? "Loading…"
        }
    }

    @ViewBuilder private var subtitle: some View {
        HStack(spacing: 10) {
            switch session.selection {
            case .lead:
                Text(FirstMateLeadBriefing.headerSubtitle(conversations: session.conversations))
            case .feature:
                if let conversation {
                    Text(FirstMateChatStatusStyle.word(for: conversation))
                        .fontWeight(FirstMateChatStatusStyle.isQuiet(conversation.hudStatus) ? .medium : .semibold)
                        .foregroundStyle(FirstMateChatStatusStyle.color(for: conversation.hudStatus))
                        .firstMateBreathing(conversation.hudStatus == .working)
                    if let step = FirstMateChatStatusStyle.stepText(for: conversation) {
                        Text(step)
                    }
                    if session.showsMachineNames {
                        Text(conversation.machineName)
                    }
                }
            }
        }
        .herdrFont(size: 11.5)
        .foregroundStyle(HerdrTheme.tertiaryText)
        .lineLimit(1)
    }
}

/// The header's inspector button: a panel glyph that reads accent on a 16%
/// accent wash while the inspector shows.
struct FirstMateInspectorToggle: View {
    let isOpen: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.right")
                .herdrFont(size: 15)
                .foregroundStyle(isOpen ? HerdrTheme.accent : isHovered ? HerdrTheme.text : HerdrTheme.iconTint)
                .frame(width: 30, height: 30)
                .background(
                    isOpen ? HerdrTheme.accent.opacity(0.16) : isHovered ? HerdrTheme.inkFill(0.08) : .clear,
                    in: .rect(cornerRadius: 8)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.herdrPlain)
        .onHover { isHovered = $0 }
        .help("Inspector (⌘I)")
        .accessibilityLabel(isOpen ? "Hide inspector" : "Show inspector")
        .accessibilityIdentifier("first-mate-chat-inspector-toggle")
    }
}

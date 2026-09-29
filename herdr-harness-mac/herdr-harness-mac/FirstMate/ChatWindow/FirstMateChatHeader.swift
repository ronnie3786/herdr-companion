import SwiftUI

/// The chat column's 60 pt header: avatar, name, a status subtitle, and the
/// inspector toggle. Empty space drags the window, like a title bar.
struct FirstMateChatHeader: View {
    let session: FirstMateChatWindowSession
    let inspectorVisible: Bool
    let toggleInspector: () -> Void
    @State private var isNameHovered = false

    var body: some View {
        HStack(spacing: 12) {
            switch session.selection {
            case .lead:
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    nameText
                    subtitle
                }
                .accessibilityElement(children: .combine)
            case .feature(let id):
                VStack(alignment: .leading, spacing: 2) {
                    Button { session.requestPresentationEdit(id) } label: {
                        HStack(spacing: 12) {
                            avatar
                            nameText
                        }
                        .padding(.trailing, 5)
                        .background(isNameHovered ? HerdrTheme.inkFill(0.08) : .clear, in: .rect(cornerRadius: 8))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.herdrPlain)
                    .onHover { isNameHovered = $0 }
                    .help("Rename or change emoji")
                    .accessibilityLabel("Rename or change emoji for \(title)")
                    subtitle.padding(.leading, 50)
                }
            }
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

    private var nameText: some View {
        Text(title)
            .herdrFont(size: 14.5, weight: .semibold)
            .tracking(-0.15)
            .foregroundStyle(HerdrTheme.text)
            .lineLimit(1)
    }

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
        case .feature: conversation?.name ?? session.selectedSnapshot?.feature.title ?? "Loading…"
        }
    }

    @ViewBuilder private var subtitle: some View {
        HStack(spacing: 10) {
            switch session.selection {
            case .lead:
                Text(FirstMateLeadBriefing.headerSubtitle(conversations: session.conversations))
                if let machineID = session.leadMachineID, session.leadMachineIDs.count > 1 {
                    // The lead lives on this Mac's machine unless one is chosen here.
                    Menu {
                        let pinned = session.leadPinnedMachineID
                        Button {
                            session.setLeadMachine(nil)
                        } label: {
                            let automatic = session.automaticLeadMachineID.map { "Automatic (\(session.machineName($0)))" } ?? "Automatic"
                            if pinned == nil {
                                Label(automatic, systemImage: "checkmark")
                            } else {
                                Text(automatic)
                            }
                        }
                        Divider()
                        ForEach(session.leadMachineIDs, id: \.self) { id in
                            Button {
                                session.setLeadMachine(id)
                            } label: {
                                if id == pinned {
                                    Label(session.machineName(id), systemImage: "checkmark")
                                } else {
                                    Text(session.machineName(id))
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(session.machineName(machineID))
                            Image(systemName: "chevron.down").herdrFont(size: 8, weight: .semibold)
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.herdrPlain)
                    .fixedSize()
                    .help("Choose which machine First Mate runs on")
                    .accessibilityLabel("First Mate on \(session.machineName(machineID)). Choose a machine")
                }
                let choice = session.leadChoice
                if !session.isDemo, choice.isFallback, let preferred = choice.preferred {
                    // Another machine's lead stands in until this one answers again.
                    Text("\(session.machineName(preferred)) is offline")
                        .foregroundStyle(HerdrTheme.warning)
                        .help("First Mate lives on \(session.machineName(preferred)). It moves back when that machine answers again.")
                }
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

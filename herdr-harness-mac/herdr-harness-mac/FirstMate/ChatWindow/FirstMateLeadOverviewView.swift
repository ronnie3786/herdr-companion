import SwiftUI

/// My First Mate's inspector until the lead First Mate exists (Phase 2): one
/// Overview tab with every feature grouped under Needs you, Moving, and Done,
/// each row with its native status and its "now" line. A row opens its chat.
///
/// Pull requests, usage, and the journal across features need fleet fields
/// that do not exist yet; they are a follow-up.
struct FirstMateLeadOverviewView: View {
    let session: FirstMateChatWindowSession
    @State private var tab = FirstMateInspector.overview

    struct StatusGroup: Identifiable {
        let title: String
        let conversations: [FirstMateConversation]
        var id: String { title }
    }

    /// Needs you (blocked, your turn, ready for review), Moving (working and
    /// ready to plan), then Done; empty groups are left out.
    static func groups(_ conversations: [FirstMateConversation]) -> [StatusGroup] {
        let needs = conversations.filter { $0.hudStatus.needsYou }
        let done = conversations.filter { $0.hudStatus == .done }
        let moving = conversations.filter { !$0.hudStatus.needsYou && $0.hudStatus != .done }
        return [StatusGroup(title: "Needs you", conversations: needs), StatusGroup(title: "Moving", conversations: moving),
                StatusGroup(title: "Done", conversations: done)]
            .filter { !$0.conversations.isEmpty }
    }

    var body: some View {
        let conversations = session.conversations
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HerdrTabs(
                    selection: $tab,
                    tabs: [.init(value: .overview, title: FirstMateInspector.overview.rawValue, accessibilityIdentifier: "first-mate-lead-tab-overview")],
                    style: .underline,
                    accessibilityLabel: "Inspector"
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: HerdrTheme.ControlHeight.bar)
            .herdrHairline(.bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your features at a glance")
                        .herdrFont(size: 15, weight: .semibold)
                        .foregroundStyle(HerdrTheme.text)
                        .padding(.top, 4)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 6) {
                        HerdrMicroLabel(text: "Goal")
                        Text("One place to ask about every feature and to start a new one.")
                            .herdrFont(size: HerdrTheme.TextSize.body)
                            .foregroundStyle(HerdrTheme.proseText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if conversations.isEmpty {
                        Text("No features yet. Describe one in the chat to start it.")
                            .herdrFont(size: HerdrTheme.TextSize.small)
                            .foregroundStyle(HerdrTheme.tertiaryText)
                    }
                    ForEach(Self.groups(conversations)) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            HerdrMicroLabel(text: group.title, count: group.conversations.count)
                                .padding(.bottom, 2)
                            ForEach(Array(group.conversations.enumerated()), id: \.element.id) { index, conversation in
                                FirstMateLeadOverviewRow(
                                    conversation: conversation,
                                    showsMachine: session.showsMachineNames,
                                    showsDivider: index < group.conversations.count - 1
                                ) {
                                    session.select(.feature(conversation.id), focusComposer: true)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.top, 14)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer(count: conversations.count)
        }
        .herdrHairline(.leading)
    }

    /// The native inspector's 32 pt sync footer.
    private func footer(count: Int) -> some View {
        let failing = session.hosts.contains { $0.error != nil }
        return HStack(spacing: 6) {
            Image(systemName: failing ? "exclamationmark.circle" : "checkmark.circle")
                .herdrFont(size: 12)
                .foregroundStyle(HerdrTheme.iconTint)
                .accessibilityHidden(true)
            Text(session.isDemo ? "Synthetic data · no agents launched" : failing ? "A machine needs attention" : "Synced with companion")
                .lineLimit(1)
            Spacer()
            Text("\(count) \(count == 1 ? "feature" : "features")")
                .monospacedDigit()
        }
        .herdrFont(size: HerdrTheme.TextSize.caption)
        .foregroundStyle(HerdrTheme.tertiaryText)
        .padding(.horizontal, 12)
        .frame(minHeight: HerdrTheme.ControlHeight.row)
        .herdrHairline(.top)
    }
}

/// A feature in the lead Overview: emoji, name, native status, and "now".
private struct FirstMateLeadOverviewRow: View {
    let conversation: FirstMateConversation
    let showsMachine: Bool
    let showsDivider: Bool
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(conversation.emoji)
                        .font(.system(size: 13))
                        .accessibilityHidden(true)
                    Text(conversation.title)
                        .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                        .foregroundStyle(isHovered ? HerdrTheme.accent : HerdrTheme.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    FirstMateStatusLabel(status: conversation.featureStatus)
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .lineLimit(1)
                }
                if let detail {
                    Text(detail)
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(HerdrTheme.tertiaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 25)
                }
            }
            .padding(.vertical, 6)
            .frame(minHeight: 30)
            .contentShape(.rect)
        }
        .buttonStyle(.herdrPlain)
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle().fill(HerdrTheme.rowDivider).frame(height: 1).accessibilityHidden(true)
            }
        }
        .help("Open \(conversation.title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([conversation.title, FirstMateChatStatusStyle.word(for: conversation), conversation.now]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens its chat")
        .accessibilityAddTraits(.isButton)
    }

    private var detail: String? {
        let now = conversation.now.flatMap { $0.isEmpty ? nil : $0 }
        guard showsMachine else { return now }
        return [conversation.machineName, now].compactMap { $0 }.joined(separator: " · ")
    }
}

import SwiftUI

/// The chat window's conversation list: First Mate's header, search, My First
/// Mate, then every feature across machines. Below 760 pt it collapses to a
/// 76 pt rail of avatars and dots.
///
/// The top 40 pt band stays clear for the traffic lights and drags the window.
struct FirstMateChatSidebar: View {
    @Bindable var session: FirstMateChatWindowSession
    let isRail: Bool
    /// Bumped by ⌘K to focus the search field.
    let searchFocusRequest: Int
    /// The ＋: selects My First Mate and focuses its composer.
    let onNewFeature: () -> Void

    enum Focus: Hashable { case search, list }
    @FocusState private var focus: Focus?
    @State private var hovered: FirstMateChatWindowSession.Selection?

    static let titleBarBand: CGFloat = HerdrTheme.ControlHeight.titleBar

    var body: some View {
        VStack(spacing: 0) {
            HerdrWindowDragArea()
                .frame(height: Self.titleBarBand)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            if !isRail {
                brand
                searchField
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    if isRail { railList } else { list }
                }
                .scrollIndicators(.never)
                .focusable(interactions: .edit)
                .focused($focus, equals: .list)
                .focusEffectDisabled()
                .onKeyPress(.upArrow) { moveSelection(by: -1, proxy: proxy) }
                .onKeyPress(.downArrow) { moveSelection(by: 1, proxy: proxy) }
            }
        }
        .onChange(of: searchFocusRequest) { _, _ in
            if isRail { return }
            focus = .search
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversations")
    }

    // MARK: Header

    private var brand: some View {
        HStack(spacing: 11) {
            FirstMateFaceOrb(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("First Mate")
                    .herdrFont(size: 15, weight: .semibold)
                    .tracking(-0.15)
                    .foregroundStyle(HerdrTheme.text)
                Text(subtitle)
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            FirstMateNewFeatureButton(action: onNewFeature)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.bottom, 12)
    }

    private var subtitle: String {
        let count = session.conversations.count
        return Self.subtitle(featureCount: count, needCount: session.badgeCount)
    }

    /// "7 features, 3 need you" / "1 feature, 1 needs you".
    nonisolated static func subtitle(featureCount: Int, needCount: Int) -> String {
        "\(featureCount) \(featureCount == 1 ? "feature" : "features"), \(needCount) \(needCount == 1 ? "needs" : "need") you"
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .herdrFont(size: 13)
                .foregroundStyle(HerdrTheme.tertiaryText)
                .accessibilityHidden(true)
            TextField("Search conversations", text: $session.search, prompt: Text(""))
                .textFieldStyle(.plain)
                .herdrPlaceholder("Search conversations", isVisible: session.search.isEmpty)
                .herdrFont(size: HerdrTheme.TextSize.body)
                .foregroundStyle(HerdrTheme.text)
                .autocorrectionDisabled()
                .focused($focus, equals: .search)
                .onKeyPress(.upArrow) { moveSelection(by: -1, proxy: nil) }
                .onKeyPress(.downArrow) { moveSelection(by: 1, proxy: nil) }
                .onKeyPress(.escape) {
                    guard !session.search.isEmpty else { return .ignored }
                    session.search = ""
                    return .handled
                }
                .accessibilityLabel("Search conversations")
                .accessibilityIdentifier("first-mate-chat-search")
            if !session.search.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { session.search = "" }
                    .buttonStyle(HerdrIconButtonStyle(visualSize: HerdrTheme.ControlHeight.small))
                    .labelStyle(.iconOnly)
                    .help("Clear search")
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .frame(height: 34)
        .background(HerdrTheme.inkFill(0.05), in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(focus == .search ? HerdrTheme.accent.opacity(0.65) : HerdrTheme.inkFill(0.08), lineWidth: 1)
        }
        .help("Search conversations (⌘K)")
    }

    // MARK: List

    private var query: String { session.search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var showsLead: Bool {
        query.isEmpty || "My First Mate".localizedCaseInsensitiveContains(query)
    }

    /// The keyboard order: My First Mate (when it matches), then the rows.
    private var order: [FirstMateChatWindowSession.Selection] {
        (showsLead ? [.lead] : []) + session.filteredConversations.map { .feature($0.id) }
    }

    private var list: some View {
        let rows = session.filteredConversations
        return LazyVStack(alignment: .leading, spacing: 0) {
            if showsLead {
                FirstMateLeadRow(
                    conversations: session.conversations,
                    isSelected: session.selection == .lead,
                    isHovered: hovered == .lead
                ) { choose(.lead) }
                .onHover { hovered = $0 ? .lead : (hovered == .lead ? nil : hovered) }
                .id(FirstMateChatWindowSession.Selection.lead)
            }
            Text("Conversations")
                .herdrFont(size: HerdrTheme.TextSize.caption, weight: .semibold)
                .foregroundStyle(HerdrTheme.tertiaryText)
                .padding(EdgeInsets(top: 12, leading: 20, bottom: 4, trailing: 20))
                .frame(maxWidth: .infinity, alignment: .leading)
                .herdrHairline(.top)
                .padding(.horizontal, -8)
                .padding(.top, 6)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, conversation in
                let selection = FirstMateChatWindowSession.Selection.feature(conversation.id)
                FirstMateConversationRow(
                    conversation: conversation,
                    isSelected: session.selection == selection,
                    isHovered: hovered == selection,
                    showsDivider: index > 0 && !isHighlighted(selection) && !isHighlighted(.feature(rows[index - 1].id))
                ) { choose(selection) }
                .onHover { hovered = $0 ? selection : (hovered == selection ? nil : hovered) }
                .id(selection)
            }
            if rows.isEmpty { emptyState }
        }
        .padding(EdgeInsets(top: 4, leading: 8, bottom: 14, trailing: 8))
    }

    private var railList: some View {
        LazyVStack(spacing: 4) {
            FirstMateRailItem(
                title: "My First Mate",
                accessibilityLabel: "My First Mate, \(FirstMateLeadBriefing.leadRowPreview(conversations: session.conversations))",
                dotColor: nil,
                isSelected: session.selection == .lead,
                isHovered: hovered == .lead
            ) {
                FirstMateFaceOrb(size: 48)
            } action: { choose(.lead) }
            .onHover { hovered = $0 ? .lead : (hovered == .lead ? nil : hovered) }
            .id(FirstMateChatWindowSession.Selection.lead)
            ForEach(session.conversations) { conversation in
                let selection = FirstMateChatWindowSession.Selection.feature(conversation.id)
                FirstMateRailItem(
                    title: conversation.title,
                    accessibilityLabel: FirstMateConversationRow.accessibilityLabel(for: conversation),
                    dotColor: conversation.showsDot ? FirstMateChatStatusStyle.dotColor(for: conversation.hudStatus) : nil,
                    isSelected: session.selection == selection,
                    isHovered: hovered == selection
                ) {
                    FirstMateEmojiDisc(emoji: conversation.emoji, size: 48)
                } action: { choose(selection) }
                .onHover { hovered = $0 ? selection : (hovered == selection ? nil : hovered) }
                .id(selection)
            }
        }
        .padding(EdgeInsets(top: 4, leading: 4, bottom: 14, trailing: 4))
    }

    @ViewBuilder private var emptyState: some View {
        Group {
            if !query.isEmpty {
                Text("No conversations match “\(query)”.")
            } else if session.hosts.contains(where: \.isLoading) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading conversations…")
                }
            } else {
                Text("No features yet. Press ＋ and tell First Mate what to build.")
            }
        }
        .herdrFont(size: HerdrTheme.TextSize.small)
        .foregroundStyle(HerdrTheme.tertiaryText)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func isHighlighted(_ selection: FirstMateChatWindowSession.Selection) -> Bool {
        session.selection == selection || hovered == selection
    }

    /// A row click. The keyboard keeps sidebar focus; a click hands focus
    /// to the chosen chat's composer when it appears.
    private func choose(_ selection: FirstMateChatWindowSession.Selection) {
        session.select(selection, focusComposer: true)
        if !session.pendingComposerFocus, focus != .search { focus = .list }
    }

    /// ↑/↓ from search or the list: moves the selection through the visible
    /// order, starting from My First Mate.
    private func moveSelection(by step: Int, proxy: ScrollViewProxy?) -> KeyPress.Result {
        let order = isRail ? [.lead] + session.conversations.map { .feature($0.id) } : order
        guard !order.isEmpty else { return .ignored }
        let next: FirstMateChatWindowSession.Selection
        if let index = order.firstIndex(of: session.selection) {
            next = order[min(max(index + step, 0), order.count - 1)]
        } else {
            next = order[step > 0 ? 0 : order.count - 1]
        }
        session.select(next)
        proxy?.scrollTo(next)
        return .handled
    }
}

// MARK: - Rows

/// The ＋ beside the title: selects My First Mate and focuses its composer,
/// which starts a new feature.
private struct FirstMateNewFeatureButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .herdrFont(size: 15, weight: .regular)
                .foregroundStyle(isHovered ? HerdrTheme.text : HerdrTheme.iconTint)
                .frame(width: 30, height: 30)
                .background(isHovered ? HerdrTheme.inkFill(0.08) : .clear, in: .rect(cornerRadius: 8))
                .contentShape(.rect)
        }
        .buttonStyle(.herdrPlain)
        .onHover { isHovered = $0 }
        .help("New feature: tell First Mate what to build")
        .accessibilityLabel("New feature")
        .accessibilityIdentifier("first-mate-chat-new-feature")
    }
}

/// The row geometry the reference uses: a 10 pt dot column, a 48 pt avatar,
/// then the text; hover and selection fills at radius 10.
private struct FirstMateSidebarRowChrome<Avatar: View, Details: View>: View {
    let dotColor: Color?
    let isSelected: Bool
    let isHovered: Bool
    let showsDivider: Bool
    @ViewBuilder let avatar: Avatar
    @ViewBuilder let text: Details

    /// Where the text column (and the divider) starts: 4 + 10 + 9 + 48 + 9.
    static var textInset: CGFloat { 80 }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                if let dotColor {
                    Circle().fill(dotColor).frame(width: 9, height: 9)
                }
            }
            .frame(width: 10)
            avatar
            text
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(top: 10, leading: 4, bottom: 10, trailing: 10))
        .background(
            isSelected ? HerdrTheme.inkFill(0.10) : isHovered ? HerdrTheme.inkFill(0.05) : .clear,
            in: .rect(cornerRadius: 10)
        )
        .overlay(alignment: .top) {
            if showsDivider {
                Rectangle()
                    .fill(HerdrTheme.hairline)
                    .frame(height: 1)
                    .padding(.leading, Self.textInset)
                    .padding(.trailing, 10)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect(cornerRadius: 10))
    }
}

/// One feature's row: dot, emoji disc, name and time, a one-line preview, and
/// the status word.
struct FirstMateConversationRow: View {
    let conversation: FirstMateConversation
    let isSelected: Bool
    let isHovered: Bool
    let showsDivider: Bool
    let action: () -> Void

    /// "Receipt export, Blocked, new message".
    static func accessibilityLabel(for conversation: FirstMateConversation) -> String {
        var parts = [conversation.title, FirstMateChatStatusStyle.word(for: conversation)]
        if conversation.showsDot { parts.append("new message") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Button(action: action) {
            FirstMateSidebarRowChrome(
                dotColor: conversation.showsDot ? FirstMateChatStatusStyle.dotColor(for: conversation.hudStatus) : nil,
                isSelected: isSelected,
                isHovered: isHovered,
                showsDivider: showsDivider
            ) {
                FirstMateEmojiDisc(emoji: conversation.emoji, size: 48)
            } text: {
                VStack(alignment: .leading, spacing: 0) {
                    FirstMateRowTopLine(name: conversation.title, date: conversation.activityAt)
                    preview
                        .padding(.top, 1)
                    FirstMateRowStatusWord(conversation: conversation)
                        .padding(.top, 3)
                }
            }
        }
        .buttonStyle(.herdrPlain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: conversation))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("first-mate-chat-row-\(conversation.featureID)")
    }

    @ViewBuilder private var preview: some View {
        if conversation.isWorkingOnReply {
            Text("typing…")
                .herdrFont(size: HerdrTheme.TextSize.small)
                .foregroundStyle(HerdrTheme.accent)
                .frame(minHeight: FirstMateRowTopLine.previewHeight, alignment: .leading)
        } else {
            Text(conversation.previewText.isEmpty ? " " : conversation.previewText)
                .herdrFont(size: HerdrTheme.TextSize.small)
                .foregroundStyle(HerdrTheme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minHeight: FirstMateRowTopLine.previewHeight, alignment: .leading)
        }
    }
}

/// Name (13.5 semibold) and time (11), baseline-aligned. The reference's
/// 1.5 line height gives the name line 20 pt and the preview 18 pt, so a row
/// is 10 + 20 + 1 + 18 + 3 + 17 + 10 = 79 pt.
private struct FirstMateRowTopLine: View {
    static let nameHeight: CGFloat = 20
    static let previewHeight: CGFloat = 18

    let name: String
    let date: Date?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name)
                .herdrFont(size: 13.5, weight: .semibold)
                .tracking(-0.07)
                .foregroundStyle(HerdrTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: Self.nameHeight, alignment: .leading)
            if let date {
                Text(FirstMateChatTime.label(for: date, now: Date(), calendar: .current))
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }
}

/// The status word in its own color, breathing while working.
private struct FirstMateRowStatusWord: View {
    let conversation: FirstMateConversation

    var body: some View {
        Text(FirstMateChatStatusStyle.word(for: conversation))
            .herdrFont(size: 11.5, weight: FirstMateChatStatusStyle.isQuiet(conversation.hudStatus) ? .medium : .semibold)
            .foregroundStyle(FirstMateChatStatusStyle.color(for: conversation.hudStatus))
            .lineLimit(1)
            .frame(minHeight: 17, alignment: .leading)
            .firstMateBreathing(conversation.hudStatus == .working)
    }
}

/// My First Mate: the face, the live briefing as its preview, and how many
/// features need you.
private struct FirstMateLeadRow: View {
    let conversations: [FirstMateConversation]
    let isSelected: Bool
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        let status = FirstMateLeadBriefing.leadRowPreview(conversations: conversations)
        Button(action: action) {
            FirstMateSidebarRowChrome(dotColor: nil, isSelected: isSelected, isHovered: isHovered, showsDivider: false) {
                FirstMateFaceOrb(size: 48)
            } text: {
                VStack(alignment: .leading, spacing: 0) {
                    FirstMateRowTopLine(name: "My First Mate", date: conversations.compactMap(\.activityAt).max())
                    Text(Self.preview(conversations: conversations))
                        .herdrFont(size: HerdrTheme.TextSize.small)
                        .foregroundStyle(HerdrTheme.tertiaryText)
                        .lineLimit(1)
                        .frame(minHeight: FirstMateRowTopLine.previewHeight, alignment: .leading)
                        .padding(.top, 1)
                    Text(status)
                        .herdrFont(size: 11.5)
                        .foregroundStyle(HerdrTheme.secondaryText)
                        .lineLimit(1)
                        .frame(minHeight: 17, alignment: .leading)
                        .padding(.top, 3)
                }
            }
        }
        .buttonStyle(.herdrPlain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("My First Mate, \(status)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("first-mate-chat-row-lead")
    }

    /// The briefing without its greeting or count, which the status line
    /// already says: "Receipt export is blocked in QA, …".
    static func preview(conversations: [FirstMateConversation]) -> String {
        let text = FirstMateLeadBriefing.build(conversations: conversations, now: Date(), calendar: .current).plainText
        if let range = text.range(of: " you: ") { return String(text[range.upperBound...]) }
        if let range = text.range(of: ". ") { return String(text[range.upperBound...]) }
        return text
    }
}

/// A rail entry: the dot and the 48 pt avatar, with the name as a tooltip.
private struct FirstMateRailItem<Avatar: View>: View {
    let title: String
    let accessibilityLabel: String
    let dotColor: Color?
    let isSelected: Bool
    let isHovered: Bool
    @ViewBuilder let avatar: Avatar
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                ZStack {
                    if let dotColor { Circle().fill(dotColor).frame(width: 9, height: 9) }
                }
                .frame(width: 10)
                avatar
            }
            .padding(EdgeInsets(top: 7, leading: 0, bottom: 7, trailing: 4))
            .frame(maxWidth: .infinity)
            .background(
                isSelected ? HerdrTheme.inkFill(0.10) : isHovered ? HerdrTheme.inkFill(0.05) : .clear,
                in: .rect(cornerRadius: 10)
            )
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.herdrPlain)
        .help(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

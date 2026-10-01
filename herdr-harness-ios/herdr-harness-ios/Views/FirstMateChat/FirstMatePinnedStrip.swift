import SwiftUI

struct FirstMatePinnedStrip: View {
    let presentation: FirstMateMobileListPresentation
    let leadUnread: Bool
    let needsYouCount: Int
    var orbSize: CGFloat = 88
    /// iPad: a grid this many across that always fits the column (My First
    /// Mate, what needs you, then "+N"). Nil keeps the iPhone's sideways row.
    var columns: Int? = nil
    let openLead: () -> Void
    let openFeature: (FirstMateFeatureTarget) -> Void
    let openInfo: (FirstMateFeatureTarget) -> Void
    let archive: (FirstMateFeatureTarget) -> Void
    let canArchive: (FirstMateFeatureTarget) -> Bool
    let revealOverflow: (FirstMateFleetFeatureID) -> Void

    var body: some View {
        if let columns { grid(columns) } else { row }
    }

    /// The pinned conversations the grid has room for, and how many it leaves out.
    private func gridSlots(_ columns: Int) -> (shown: [FirstMateConversation], hidden: [FirstMateConversation]) {
        let needs = presentation.pinned + presentation.overflow
        let room = columns - (presentation.showsLead ? 1 : 0)
        guard needs.count > room else { return (needs, []) }
        let shown = Array(needs.prefix(max(0, room - 1)))
        return (shown, Array(needs.dropFirst(shown.count)))
    }

    private func grid(_ columns: Int) -> some View {
        let slots = gridSlots(columns)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4, alignment: .top), count: columns), spacing: 8) {
            if presentation.showsLead { leadAvatar }
            ForEach(slots.shown) { row in featureAvatar(row) }
            if let first = slots.hidden.first {
                overflowButton(count: slots.hidden.count, first: first.id)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .accessibilityIdentifier("first-mate-chat-pinned-strip")
    }

    private var leadAvatar: some View {
        FirstMatePinnedAvatar(name: "My First Mate", emoji: nil, size: orbSize, unread: leadUnread,
            tint: HerdrTheme.accent, caption: needsYouCount == 0 ? "Nothing needs you" : "\(needsYouCount) \(needsYouCount == 1 ? "needs" : "need") you",
            identifier: "first-mate-chat-pinned-lead", compact: columns != nil, action: openLead)
            .contextMenu { Button("Open overview", systemImage: "info.circle", action: openLead) }
    }

    private func featureAvatar(_ row: FirstMateConversation) -> some View {
        let target = FirstMateMobileListPresentation.target(row)
        return FirstMatePinnedAvatar(name: row.name, emoji: row.emoji, size: orbSize, unread: row.showsDot,
            tint: FirstMateChatStatusStyle.dotColor(for: row.hudStatus), caption: nil,
            identifier: "first-mate-chat-pinned-\(row.machineID)-\(row.featureID)", compact: columns != nil,
            action: { openFeature(target) })
            .accessibilityLabel("\(row.name), \(FirstMateChatStatusStyle.word(for: row))\(row.showsDot ? ", new message" : ""), \(row.machineName)")
            .contextMenu {
                Button("Open info", systemImage: "info.circle") { openInfo(target) }
                Button("Archive…", systemImage: "archivebox") { archive(target) }.disabled(!canArchive(target))
            }
    }

    private func overflowButton(count: Int, first: FirstMateFleetFeatureID) -> some View {
        Button { revealOverflow(first) } label: {
            VStack(spacing: 8) {
                Text("+\(count)")
                    .herdrFont(.title3, weight: .semibold)
                    .frame(width: orbSize, height: orbSize)
                    .background(HerdrTheme.chipFill, in: .circle)
                Text("More").herdrFont(.caption, weight: .medium)
            }
            .foregroundStyle(HerdrTheme.secondaryText)
            .frame(maxWidth: columns == nil ? max(96, orbSize) : .infinity, alignment: .top)
            .contentShape(.rect)
        }
        .buttonStyle(.herdrPlain)
        .accessibilityLabel("\(count) more conversations need you. Show the first hidden conversation.")
        .accessibilityIdentifier("first-mate-chat-pinned-overflow")
    }

    private var row: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 24) {
                if presentation.showsLead {
                    FirstMatePinnedAvatar(name: "My First Mate", emoji: nil, size: orbSize, unread: leadUnread,
                        tint: HerdrTheme.accent, caption: needsYouCount == 0 ? "Nothing needs you" : "\(needsYouCount) \(needsYouCount == 1 ? "needs" : "need") you",
                        identifier: "first-mate-chat-pinned-lead", action: openLead)
                        .contextMenu { Button("Open overview", systemImage: "info.circle", action: openLead) }
                }
                ForEach(presentation.pinned) { row in
                    let target = FirstMateMobileListPresentation.target(row)
                    FirstMatePinnedAvatar(name: row.name, emoji: row.emoji, size: orbSize, unread: row.showsDot,
                        tint: FirstMateChatStatusStyle.dotColor(for: row.hudStatus), caption: nil,
                        identifier: "first-mate-chat-pinned-\(row.machineID)-\(row.featureID)",
                        action: { openFeature(target) })
                        .accessibilityLabel("\(row.name), \(FirstMateChatStatusStyle.word(for: row))\(row.showsDot ? ", new message" : ""), \(row.machineName)")
                        .contextMenu {
                            Button("Open info", systemImage: "info.circle") { openInfo(target) }
                            Button("Archive…", systemImage: "archivebox") { archive(target) }.disabled(!canArchive(target))
                        }
                }
                if let first = presentation.overflow.first {
                    Button { revealOverflow(first.id) } label: {
                        VStack(spacing: 8) {
                            Text("+\(presentation.overflow.count)")
                                .herdrFont(.title3, weight: .semibold)
                                .frame(width: orbSize, height: orbSize)
                                .background(HerdrTheme.chipFill, in: .circle)
                            Text("More").herdrFont(.caption, weight: .medium)
                        }
                        .foregroundStyle(HerdrTheme.secondaryText)
                        .frame(width: max(96, orbSize), alignment: .top)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.herdrPlain)
                    .accessibilityLabel("\(presentation.overflow.count) more conversations need you. Show the first hidden conversation.")
                    .accessibilityIdentifier("first-mate-chat-pinned-overflow")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("first-mate-chat-pinned-strip")
    }
}

private struct FirstMatePinnedAvatar: View {
    let name: String
    let emoji: String?
    let size: CGFloat
    let unread: Bool
    let tint: Color
    let caption: String?
    let identifier: String
    /// Grid cells share the column's width and wrap names onto two lines.
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Group {
                    if let emoji { FirstMateEmojiDisc(emoji: emoji, size: size) }
                    else { FirstMateFaceOrb(size: size) }
                }
                .overlay(alignment: .topTrailing) {
                    if unread {
                        Circle().fill(tint).frame(width: 12, height: 12)
                            .overlay { Circle().strokeBorder(HerdrTheme.railBackground, lineWidth: 2) }
                            .accessibilityHidden(true)
                    }
                }
                Text(name).herdrFont(.caption, weight: .medium)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .lineLimit(emoji == nil || compact ? 2 : 1)
                    .multilineTextAlignment(.center)
                if let caption {
                    Text(caption).herdrFont(.caption2).foregroundStyle(HerdrTheme.tertiaryText)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: compact ? nil : max(96, size), alignment: .top)
            .frame(maxWidth: compact ? .infinity : nil, alignment: .top)
            .contentShape(.rect)
        }
        .buttonStyle(.herdrPlain)
        .accessibilityLabel(name + (unread ? ", unread reply" : "") + (caption.map { ", " + $0 } ?? ""))
        .accessibilityIdentifier(identifier)
        .composerLayoutMeasurement(id: identifier, label: name)
    }
}

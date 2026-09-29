import SwiftUI

struct FirstMatePinnedStrip: View {
    let presentation: FirstMateMobileListPresentation
    let leadUnread: Bool
    let needsYouCount: Int
    var orbSize: CGFloat = 88
    let openLead: () -> Void
    let openFeature: (FirstMateFeatureTarget) -> Void
    let openInfo: (FirstMateFeatureTarget) -> Void
    let archive: (FirstMateFeatureTarget) -> Void
    let canArchive: (FirstMateFeatureTarget) -> Bool
    let revealOverflow: (FirstMateFleetFeatureID) -> Void

    var body: some View {
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
                    .lineLimit(emoji == nil ? 2 : 1)
                    .multilineTextAlignment(.center)
                if let caption {
                    Text(caption).herdrFont(.caption2).foregroundStyle(HerdrTheme.tertiaryText)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: max(96, size), alignment: .top)
            .contentShape(.rect)
        }
        .buttonStyle(.herdrPlain)
        .accessibilityLabel(name + (unread ? ", unread reply" : "") + (caption.map { ", " + $0 } ?? ""))
        .accessibilityIdentifier(identifier)
        .composerLayoutMeasurement(id: identifier, label: name)
    }
}

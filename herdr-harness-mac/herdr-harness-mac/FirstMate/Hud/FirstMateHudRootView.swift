import SwiftUI

/// The First Mate HUD panel's content. Every piece is placed from
/// ``FirstMateHudController/layout``, which also sized the panel, so the face
/// stays put while the list and cards open around it.
struct FirstMateHudRootView: View {
    let controller: FirstMateHudController
    @AppStorage(HerdrAppearancePreferences.glassEnabledKey) private var glassEnabled = HerdrAppearancePreferences.defaultGlassEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var layout: FirstMateHudGeometry.Output { controller.layout }
    private var face: CGPoint { layout.faceCenter }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if controller.isExpanded {
                expandedColumn
            } else {
                collapsedColumn
            }
            FirstMateHudFaceView(controller: controller)
                .position(face)
            if let card = controller.visibleCard, let frame = layout.cardFrame {
                FirstMateHudCardView(controller: controller, card: card)
                    .frame(width: frame.width, height: frame.height, alignment: .top)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        // No layout animation: the panel moves the moment the layout changes,
        // so anything placed from its origin (the face, the orbs) must not
        // animate there, or it would visibly slide away and back.
        .frame(width: layout.panelFrame.width, height: layout.panelFrame.height, alignment: .topLeading)
        .transaction { $0.animation = nil }
        .environment(\.herdrGlassActive, HerdrGlass.isActive(enabled: glassEnabled, reduceTransparency: reduceTransparency, colorScheme: .dark))
        .preferredColorScheme(.dark)
        .tint(HerdrTheme.accent)
        .foregroundStyle(HerdrTheme.primaryText)
    }

    // MARK: Collapsed

    private var collapsedColumn: some View {
        let collapsed = controller.collapsed
        let count = collapsed.orbs.count + (collapsed.hasMore ? 1 : 0)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(collapsed.orbs.enumerated()), id: \.element.id) { index, item in
                let center = FirstMateHudGeometry.orbCenter(index: index, count: count)
                orbButton(item)
                    .position(x: face.x + center.x, y: face.y + center.y)
            }
            if collapsed.hasMore {
                let center = FirstMateHudGeometry.orbCenter(index: count - 1, count: count)
                Button(action: controller.openTucked) {
                    FirstMateHudMoreOrb(tucked: collapsed.tucked)
                        .contentShape(Circle())
                }
                .buttonStyle(.herdrPlain)
                .onHover { controller.hover(.tucked, isInside: $0) }
                .accessibilityLabel("\(collapsed.tucked.count) more features. Opens the list.")
                .position(x: face.x + center.x, y: face.y + center.y)
            }
            if !controller.items.isEmpty {
                FirstMateHudChevron(isExpanded: false) { controller.setExpanded(true) }
                    .position(x: face.x, y: face.y + FirstMateHudGeometry.collapsedBottom(orbCount: count) - FirstMateHudGeometry.chevronSize / 2)
            }
        }
    }

    private func orbButton(_ item: FirstMateHudItem) -> some View {
        Button { controller.activateOrb(item.id) } label: {
            FirstMateHudHaloOrb(item: item)
                .contentShape(Circle())
        }
        .buttonStyle(.herdrPlain)
        .onHover { controller.hover(.readout(item.id), isInside: $0) }
        .contextMenu { FirstMateHudItemMenu(controller: controller, item: item) }
        .accessibilityLabel(FirstMateHudSpeech.accessibilityLabel(item, opensMessage: true))
    }

    // MARK: Expanded

    private var expandedColumn: some View {
        let side = layout.listSide
        let lane = FirstMateHudGeometry.nodeLane
        let width = FirstMateHudGeometry.listReach + lane / 2
        let top = face.y + FirstMateHudGeometry.listTop
        let viewport = layout.listViewportHeight
        let content = FirstMateHudGeometry.listContentHeight(controller.expanded)
        let lastCenter = lastNodeCenter()
        let lineBottom = min(lastCenter, viewport)
        let originX = side == .trailing ? face.x - lane / 2 : face.x + lane / 2 - width
        return ZStack(alignment: .topLeading) {
            // The lit line from the face down through every node.
            FirstMateHudLine()
                .frame(width: 6, height: max(0, FirstMateHudGeometry.listTop - FirstMateHudGeometry.faceRadius + lineBottom))
                .position(x: face.x, y: face.y + FirstMateHudGeometry.faceRadius
                          + (FirstMateHudGeometry.listTop - FirstMateHudGeometry.faceRadius + lineBottom) / 2)
            FirstMateHudChevron(isExpanded: true) { controller.setExpanded(false) }
                .position(x: face.x, y: face.y + FirstMateHudGeometry.faceRadius + 6 + FirstMateHudGeometry.chevronSize / 2)
            Group {
                if content > viewport + 0.5 {
                    ScrollView(.vertical) { rows(side: side) }
                        .scrollIndicators(.never)
                } else {
                    rows(side: side)
                }
            }
            .frame(width: width, height: viewport, alignment: .top)
            .position(x: originX + width / 2, y: top + viewport / 2)
        }
    }

    /// The last node's center below the list top, where the line ends.
    private func lastNodeCenter() -> CGFloat {
        let expanded = controller.expanded
        let height = FirstMateHudGeometry.listContentHeight(expanded)
        guard height > 0 else { return 0 }
        let lastIsCompact = expanded.summary == nil && expanded.movingAreCompact && !expanded.moving.isEmpty
        let lastPitch = lastIsCompact ? FirstMateHudGeometry.compactPitch : FirstMateHudGeometry.rowPitch
        let lastHeight = lastIsCompact ? FirstMateHudGeometry.compactHeight : FirstMateHudGeometry.slatHeight
        return height - lastPitch + lastHeight / 2
    }

    private func rows(side: FirstMateHudGeometry.Side) -> some View {
        let expanded = controller.expanded
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(expanded.needsYou) { item in
                FirstMateHudRow(controller: controller, item: item, side: side, compact: false)
                    .frame(height: FirstMateHudGeometry.rowPitch, alignment: .top)
            }
            if !expanded.needsYou.isEmpty, !expanded.moving.isEmpty || expanded.summary != nil {
                FirstMateHudDiamond(side: side)
                    .frame(height: FirstMateHudGeometry.groupGap)
            }
            ForEach(expanded.moving) { item in
                FirstMateHudRow(controller: controller, item: item, side: side, compact: expanded.movingAreCompact)
                    .frame(height: expanded.movingAreCompact ? FirstMateHudGeometry.compactPitch : FirstMateHudGeometry.rowPitch,
                           alignment: .top)
            }
            if let summary = expanded.summary {
                FirstMateHudSummaryRow(controller: controller, summary: summary, side: side)
                    .frame(height: FirstMateHudGeometry.rowPitch, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The accent line the rows hang from.
struct FirstMateHudLine: View {
    var body: some View {
        Capsule()
            .fill(HerdrTheme.accent.opacity(0.55))
            .frame(width: 1.5)
            .shadow(color: HerdrTheme.accent.opacity(0.7), radius: 3)
            .accessibilityHidden(true)
    }
}

/// The small diamond on the line between the needs-you rows and the rest.
struct FirstMateHudDiamond: View {
    let side: FirstMateHudGeometry.Side

    var body: some View {
        HStack(spacing: 0) {
            if side == .leading { Spacer(minLength: 0) }
            Rectangle()
                .fill(HerdrTheme.accent.opacity(0.75))
                .frame(width: 6, height: 6)
                .rotationEffect(.degrees(45))
                .frame(width: FirstMateHudGeometry.nodeLane)
            if side == .trailing { Spacer(minLength: 0) }
        }
        .accessibilityHidden(true)
    }
}

/// The 22 pt button that opens or collapses the list.
struct FirstMateHudChevron: View {
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(HerdrTheme.secondaryText)
                .frame(width: FirstMateHudGeometry.chevronSize, height: FirstMateHudGeometry.chevronSize)
                .background(Circle().fill(HerdrTheme.windowBackground.opacity(0.86)))
                .overlay { Circle().strokeBorder(HerdrTheme.outline, lineWidth: 1) }
                .contentShape(Circle())
        }
        .buttonStyle(.herdrPlain)
        .accessibilityLabel(isExpanded ? "Collapse the list" : "Show the list")
    }
}

/// One expanded row: the node on the line, the glass slat, and the unread
/// bubble. Needs-you slats take a border in their status color.
struct FirstMateHudRow: View {
    let controller: FirstMateHudController
    let item: FirstMateHudItem
    let side: FirstMateHudGeometry.Side
    let compact: Bool

    var body: some View {
        HStack(spacing: FirstMateHudGeometry.slatGap) {
            if side == .trailing {
                node
                slat
                bubble
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                bubble
                slat
                node
            }
        }
        .frame(height: compact ? FirstMateHudGeometry.compactHeight : FirstMateHudGeometry.slatHeight)
        .contentShape(Rectangle())
        .onHover { controller.hover(.readout(item.id), isInside: $0) }
    }

    private var node: some View {
        Button { controller.activateOrb(item.id) } label: {
            FirstMateHudHaloOrb(item: item, size: compact ? FirstMateHudGeometry.compactNode - 2 : FirstMateHudGeometry.nodeLane - 2)
                .frame(width: FirstMateHudGeometry.nodeLane)
                .contentShape(Circle())
        }
        .buttonStyle(.herdrPlain)
        .accessibilityHidden(true)
    }

    private var slat: some View {
        Button { controller.openSession(item.id) } label: {
            Group {
                if compact { compactContent } else { fullContent }
            }
            .padding(.horizontal, 10)
            .frame(width: FirstMateHudGeometry.slatWidth, height: compact ? FirstMateHudGeometry.compactHeight : FirstMateHudGeometry.slatHeight)
            .firstMateHudCard(cornerRadius: compact ? 7 : 9, tint: item.needsYou ? FirstMateChatStatusStyle.dotColor(for: item.hudStatus) : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.herdrPlain)
        .contextMenu { FirstMateHudItemMenu(controller: controller, item: item) }
        .accessibilityLabel(FirstMateHudSpeech.accessibilityLabel(item))
        .onKeyPress("e") {
            controller.openExplicit(.editor(item.id))
            return .handled
        }
    }

    private var fullContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(item.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HerdrTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                stateWord(size: 11)
            }
            HStack(spacing: 8) {
                FirstMateHudStepBar(item: item)
                Text(item.percent.map { "\($0)%" } ?? "")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .frame(width: 30, alignment: .trailing)
            }
        }
    }

    private var compactContent: some View {
        HStack(spacing: 6) {
            Text(item.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(HerdrTheme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            stateWord(size: 10)
            Text(item.percent.map { "\($0)%" } ?? "")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(HerdrTheme.tertiaryText)
                .frame(width: 28, alignment: .trailing)
        }
        .overlay(alignment: .bottom) {
            FirstMateHudStepBar(item: item, height: 2, spacing: 2)
                .offset(y: 7)
        }
    }

    private func stateWord(size: CGFloat) -> some View {
        Text(item.stateWord)
            .font(.system(size: size, weight: FirstMateChatStatusStyle.isQuiet(item.hudStatus) ? .medium : .semibold))
            .foregroundStyle(FirstMateChatStatusStyle.color(for: item.hudStatus))
            .lineLimit(1)
            // No breathing here: the HUD floats all day, and only the blink
            // may animate while nothing changes.
    }

    @ViewBuilder private var bubble: some View {
        if item.showsDot && !compact {
            Button { controller.openExplicit(.message(item.id)) } label: {
                // The tail points back at the slat on either side.
                FirstMateHudSpeechBubble()
                    .scaleEffect(x: side == .trailing ? 1 : -1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.herdrPlain)
            .accessibilityLabel("Read the message from \(item.label)")
        } else if !compact {
            Color.clear.frame(width: FirstMateHudGeometry.bubbleSize.width, height: 1)
        }
    }
}

/// "N more moving" with their emoji and average progress; clicking shows
/// every moving row, compact, and the row then reads "Show fewer".
struct FirstMateHudSummaryRow: View {
    let controller: FirstMateHudController
    let summary: FirstMateHudOverflow.Summary
    let side: FirstMateHudGeometry.Side

    var body: some View {
        HStack(spacing: FirstMateHudGeometry.slatGap) {
            if side == .trailing {
                node
                slat
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                slat
                node
            }
        }
        .frame(height: FirstMateHudGeometry.slatHeight)
        .onHover { inside in
            if !summary.isShowingAll { controller.hover(.tucked, isInside: inside) }
        }
    }

    private var node: some View {
        FirstMateHudMoreOrb(tucked: summary.isShowingAll ? [] : summary.tucked, size: FirstMateHudGeometry.nodeLane - 2,
                            showsCount: !summary.isShowingAll)
            .overlay {
                if summary.isShowingAll {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(HerdrTheme.secondaryText)
                }
            }
            .frame(width: FirstMateHudGeometry.nodeLane)
            .accessibilityHidden(true)
    }

    private var slat: some View {
        Button(action: controller.toggleShowAllMoving) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(summary.isShowingAll ? "All moving features" : "\(summary.count) more moving")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HerdrTheme.secondaryText)
                    Spacer(minLength: 4)
                    Text(summary.isShowingAll ? "Show fewer" : "Show all")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HerdrTheme.accent)
                }
                if !summary.isShowingAll {
                    HStack(spacing: 3) {
                        Text(summary.tucked.prefix(8).map(\.emoji).joined())
                            .font(.system(size: 10))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(summary.averagePercent.map { "\($0)%" } ?? "")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(HerdrTheme.tertiaryText)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(width: FirstMateHudGeometry.slatWidth, height: FirstMateHudGeometry.slatHeight)
            .firstMateHudCard(cornerRadius: 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.herdrPlain)
        .accessibilityLabel(summary.isShowingAll ? "Show fewer moving features" : "\(summary.count) more moving features. Shows them all.")
    }
}

/// The right-click menu for a feature's orb or row.
struct FirstMateHudItemMenu: View {
    let controller: FirstMateHudController
    let item: FirstMateHudItem

    var body: some View {
        Button("Open Session") { controller.openSession(item.id) }
        if item.showsDot {
            Button("Read Message") { controller.openExplicit(.message(item.id)) }
        }
        Divider()
        Button("Rename or Change Emoji…") { controller.openExplicit(.editor(item.id)) }
    }
}

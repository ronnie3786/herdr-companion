import SwiftUI

/// A feature pill in My First Mate's briefing: a 17 pt emoji disc, the name,
/// and a 6 pt status dot on a tint of the status color. Hovering 200 ms shows
/// the readout; clicking opens the chat.
struct FirstMateCapsuleView: View {
    let conversation: FirstMateConversation
    /// The conversation the window shows, so the readout says "This chat".
    var isCurrent = false
    let open: () -> Void

    @State private var hovering = false
    @State private var readoutShown = false
    @State private var readoutHovered = false
    @State private var hoverTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    static let height: CGFloat = 21
    /// Just under half the height, which reads as the 11 pt pill without the
    /// stray edge segment an exact half-height radius draws offscreen.
    static let radius: CGFloat = 10
    static let hoverDelay: Duration = .milliseconds(200)
    static let hideDelay: Duration = .milliseconds(160)

    private var tint: Color { FirstMateChatStatusStyle.tintColor(for: conversation.hudStatus) }
    private var isActive: Bool { hovering || focused || readoutShown }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                ZStack {
                    Circle().fill(HerdrTheme.firstMateAvatarFill)
                    Text(conversation.emoji).font(.system(size: 10))
                }
                .frame(width: 17, height: 17)
                Text(conversation.title)
                    .herdrFont(size: HerdrTheme.TextSize.small, weight: .semibold)
                    .foregroundStyle(HerdrTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 200, alignment: .leading)
                    .fixedSize()
                Circle().fill(tint).frame(width: 6, height: 6)
            }
            .padding(.leading, 2)
            .padding(.trailing, 8)
            .frame(height: Self.height)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: Self.radius).fill(HerdrTheme.inkFill(0.06))
                    RoundedRectangle(cornerRadius: Self.radius).fill(tint.opacity(isActive ? 0.22 : 0.11))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: Self.radius).strokeBorder(tint.opacity(isActive ? 1 : 0.36), lineWidth: 1))
            .contentShape(.capsule)
        }
        .buttonStyle(.herdrPlain)
        .focused($focused)
        .animation(.easeOut(duration: 0.12), value: isActive)
        .onHover(perform: hoverChanged)
        .onChange(of: focused) { _, isFocused in
            // A focused capsule shows its readout at once.
            if isFocused { readoutShown = true } else if !hovering { readoutShown = false }
        }
        .popover(isPresented: $readoutShown, arrowEdge: .bottom) {
            FirstMateCapsuleReadout(conversation: conversation, isCurrent: isCurrent, showsChrome: false) {
                readoutShown = false
                open()
            }
            .onHover { inside in
                readoutHovered = inside
                if !inside { scheduleHide() }
            }
        }
        .onDisappear { hoverTask?.cancel() }
        .accessibilityLabel("\(conversation.title), \(FirstMateChatStatusStyle.word(for: conversation)). Opens its chat.")
    }

    private func hoverChanged(_ inside: Bool) {
        hovering = inside
        hoverTask?.cancel()
        if inside {
            hoverTask = Task {
                try? await Task.sleep(for: Self.hoverDelay)
                guard !Task.isCancelled, hovering else { return }
                readoutShown = true
            }
        } else {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hoverTask?.cancel()
        hoverTask = Task {
            try? await Task.sleep(for: Self.hideDelay)
            guard !Task.isCancelled, !hovering, !readoutHovered, !focused else { return }
            readoutShown = false
        }
    }
}

/// The readout a capsule shows: avatar, name, status, the "now" line, six
/// step bars, "Step n of 6", and "Open chat".
struct FirstMateCapsuleReadout: View {
    let conversation: FirstMateConversation
    var isCurrent = false
    /// Draws the card's own float fill, edge, and shadow. A popover already
    /// has chrome, so it passes false.
    var showsChrome = true
    let open: () -> Void

    static let width: CGFloat = 280

    /// Progress through the six steps: all six when done, else the step plus
    /// its fraction; nil when the step is unknown.
    static func progress(for conversation: FirstMateConversation) -> Double? {
        if conversation.hudStatus == .done { return Double(FirstMateChatSteps.names.count) }
        guard let step = conversation.stepIndex else { return nil }
        return Double(step) + (conversation.stepFraction ?? 0)
    }

    /// How full bar `index` (0...5) is.
    static func fill(bar index: Int, progress: Double?) -> Double {
        guard let progress else { return 0 }
        return min(max(progress - Double(index), 0), 1)
    }

    var body: some View {
        let color = FirstMateChatStatusStyle.dotColor(for: conversation.hudStatus)
        let progress = Self.progress(for: conversation)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                FirstMateEmojiDisc(emoji: conversation.emoji, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.title)
                        .herdrFont(size: 13, weight: .semibold)
                        .foregroundStyle(HerdrTheme.primaryText)
                        .lineLimit(1)
                    Text(FirstMateChatStatusStyle.word(for: conversation))
                        .herdrFont(size: 11.5, weight: FirstMateChatStatusStyle.isQuiet(conversation.hudStatus) ? .medium : .semibold)
                        .foregroundStyle(FirstMateChatStatusStyle.color(for: conversation.hudStatus))
                        .lineLimit(1)
                }
            }
            if let now = conversation.now, !now.isEmpty {
                Text(now)
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.proseText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)
            }
            HStack(spacing: 3) {
                ForEach(0..<FirstMateChatSteps.names.count, id: \.self) { index in
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(HerdrTheme.inkFill(0.10))
                            Capsule().fill(color)
                                .frame(width: geometry.size.width * Self.fill(bar: index, progress: progress))
                        }
                    }
                    .frame(height: 3)
                }
            }
            .padding(.top, 11)
            .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline) {
                Text(FirstMateChatStatusStyle.stepText(for: conversation) ?? "Step unknown")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isCurrent {
                    Text("This chat")
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(HerdrTheme.tertiaryText)
                } else {
                    Button("Open chat", action: open)
                        .buttonStyle(.herdrPlain)
                        .herdrFont(size: 11.5, weight: .semibold)
                        .foregroundStyle(HerdrTheme.accent)
                }
            }
            .padding(.top, 9)
        }
        .padding(.top, 12)
        .padding(.horizontal, 13)
        .padding(.bottom, 11)
        .frame(width: Self.width, alignment: .leading)
        .background {
            if showsChrome {
                RoundedRectangle(cornerRadius: 12).fill(FirstMateMentionPicker.floatFill)
                    .shadow(color: .black.opacity(0.45), radius: 20, y: 18)
            }
        }
        .overlay {
            if showsChrome { RoundedRectangle(cornerRadius: 12).strokeBorder(HerdrTheme.outline, lineWidth: 1) }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Lays words and pills out like running text: left to right, wrapping to
/// new lines, each line's items centered on one another.
struct FirstMateFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(for subviews: Subviews, width: CGFloat) -> (lines: [Line], sizes: [CGSize]) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var lines: [Line] = [Line()]
        for (index, size) in sizes.enumerated() {
            let gap = lines[lines.count - 1].indices.isEmpty ? 0 : subviews[index][FirstMateFlowGap.self] ?? spacing
            if !lines[lines.count - 1].indices.isEmpty, lines[lines.count - 1].width + gap + size.width > width {
                lines.append(Line())
            }
            var line = lines[lines.count - 1]
            let actualGap = line.indices.isEmpty ? 0 : gap
            line.indices.append(index)
            line.width += actualGap + size.width
            line.height = max(line.height, size.height)
            lines[lines.count - 1] = line
        }
        return (lines, sizes)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let (lines, _) = lines(for: subviews, width: width)
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        let used = lines.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (lines, sizes) = lines(for: subviews, width: bounds.width)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for (position, index) in line.indices.enumerated() {
                if position > 0 { x += subviews[index][FirstMateFlowGap.self] ?? spacing }
                let size = sizes[index]
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width
            }
            y += line.height + lineSpacing
        }
    }
}

/// The gap before an item in ``FirstMateFlowLayout``; punctuation that follows
/// a pill sits against it.
struct FirstMateFlowGap: LayoutValueKey {
    static let defaultValue: CGFloat? = nil
}

/// My First Mate's briefing as flowing words and pills.
struct FirstMateBriefingFlow: View {
    let segments: [FirstMateLeadBriefing.Segment]
    var currentID: FirstMateFleetFeatureID? = nil
    let open: (FirstMateConversation) -> Void

    enum Item: Identifiable {
        case word(String, gap: CGFloat?, index: Int)
        case mention(FirstMateConversation, gap: CGFloat?, index: Int)

        var id: Int {
            switch self {
            case .word(_, _, let index), .mention(_, _, let index): index
            }
        }
    }

    /// Words keep their punctuation; a word that starts right after a pill
    /// with no space (", and") hugs it.
    static func items(for segments: [FirstMateLeadBriefing.Segment]) -> [Item] {
        var items: [Item] = []
        for segment in segments {
            switch segment {
            case .text(let text):
                let startsTight = !(text.first?.isWhitespace ?? true)
                let words = text.split(whereSeparator: \.isWhitespace)
                for (offset, word) in words.enumerated() {
                    let gap: CGFloat? = offset == 0 && startsTight && !items.isEmpty ? 0 : nil
                    items.append(.word(String(word), gap: gap, index: items.count))
                }
            case .mention(let conversation):
                items.append(.mention(conversation, gap: nil, index: items.count))
            }
        }
        return items
    }

    var body: some View {
        FirstMateFlowLayout(spacing: 4, lineSpacing: 5) {
            ForEach(Self.items(for: segments)) { item in
                switch item {
                case .word(let word, let gap, _):
                    Text(word)
                        .herdrFont(size: 13.5)
                        .foregroundStyle(HerdrTheme.proseText)
                        .fixedSize()
                        .layoutValue(key: FirstMateFlowGap.self, value: gap)
                case .mention(let conversation, let gap, _):
                    FirstMateCapsuleView(conversation: conversation, isCurrent: conversation.id == currentID) {
                        open(conversation)
                    }
                    .layoutValue(key: FirstMateFlowGap.self, value: gap)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

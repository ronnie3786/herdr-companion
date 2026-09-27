import SwiftUI

/// What an open excerpt shows. It carries the reader it was opened from, so
/// the message keeps showing that skim until the excerpt closes.
struct SkimExcerptRequest: Identifiable, Equatable {
    enum Source: Hashable {
        case sentence
        case caveat(Int)
        case rest
        case nextStep(Int)
    }

    let id = UUID()
    let reader: FirstMateSkimReader
    let refs: [String]
    let anchorID: String?
    let title: String
    let source: Source
}

enum SkimDisplay {
    /// The skim a message shows. While an excerpt is open, the skim it came
    /// from stays on screen; a newer one swaps in (without animation) once
    /// the excerpt closes. Nil means the full reply.
    static func reader(live: FirstMateSkimReader?, presented: SkimExcerptRequest?) -> FirstMateSkimReader? {
        guard let reader = presented?.reader ?? live else { return nil }
        return hasContent(reader) ? reader : nil
    }

    /// A skim with nothing to say is no better than no skim.
    static func hasContent(_ reader: FirstMateSkimReader) -> Bool {
        !reader.sentence.isEmpty || !reader.caveats.isEmpty || !reader.nextSteps.isEmpty
    }
}

/// A long reply as its skim (One breath, tight): one linked sentence, any
/// caveat, a "Rest of the original" chip, the suggested next step last, and
/// a footer that switches to the full reply. Without a ready skim that is
/// valid for this exact reply, it shows `fullReply` unchanged.
///
/// A tap on a phrase or the chip opens the verbatim excerpt: a sheet in
/// compact width, a popover in regular width. Nothing here animates.
struct SkimmableReply<FullReply: View>: View {
    let messageID: String
    /// From `FirstMateSkimReader(skim:reply:)`; nil means "show the full reply".
    let reader: FirstMateSkimReader?
    let style: SkimStyle
    let state: SkimReadingState
    @ViewBuilder let fullReply: () -> FullReply

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var askDot: CGFloat = 7
    @State private var presented: SkimExcerptRequest?

    var body: some View {
        content
            .transaction { $0.animation = nil }
            .sheet(item: sheetBinding) { request in
                excerpt(request, presentation: .sheet)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(style.sourceSurface)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let reader = SkimDisplay.reader(live: reader, presented: presented) {
            if state.showsFullReply(messageID) {
                fullReplyBody(reader)
            } else {
                skimBody(reader)
            }
        } else {
            fullReply()
                .composerLayoutMeasurement(id: "skim-full-reply")
        }
    }

    // MARK: - Skim

    private func skimBody(_ reader: FirstMateSkimReader) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !reader.sentence.isEmpty {
                linkedText(reader.sentence, reader: reader, source: .sentence, font: style.sentenceFont, color: style.text)
                    .composerLayoutMeasurement(id: "skim-sentence")
            }
            ForEach(Array(reader.caveats.enumerated()), id: \.offset) { index, caveat in
                linkedText(caveat, reader: reader, source: .caveat(index), font: style.caveatFont, color: style.secondaryText)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(style.alert.opacity(0.7))
                            .frame(width: 2)
                            .accessibilityHidden(true)
                    }
                    .composerLayoutMeasurement(id: "skim-caveat-\(index)")
            }
            if reader.restCount > 0 {
                restChip(reader)
            }
            ForEach(Array(reader.nextSteps.enumerated()), id: \.offset) { index, step in
                nextStep(step, index: index, reader: reader)
                    .composerLayoutMeasurement(id: "skim-next-step-\(index)")
            }
            footer(reader, showsFullReply: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func linkedText(
        _ tokens: [SkimToken],
        reader: FirstMateSkimReader,
        source: SkimExcerptRequest.Source,
        font: Font,
        color: Color
    ) -> some View {
        Text(SkimText.attributed(tokens, style: style, color: color, openAnchorID: presented?.anchorID))
            .font(font)
            .lineSpacing(style.lineSpacing)
            .foregroundStyle(color)
            // Links would take the accent; anchors keep the text color.
            .tint(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                guard let id = SkimText.anchorID(in: url) else { return .systemAction }
                openAnchor(id, reader: reader, source: source)
                return .handled
            })
            .accessibilityActions {
                ForEach(SkimText.mentions(in: tokens), id: \.id) { mention in
                    Button(actionName(mention, reader: reader)) {
                        openAnchor(mention.id, reader: reader, source: source)
                    }
                }
            }
            .popover(item: popoverBinding(source), attachmentAnchor: .rect(.bounds)) { request in
                excerpt(request, presentation: .popover)
            }
    }

    private func actionName(_ mention: SkimText.Mention, reader: FirstMateSkimReader) -> String {
        let refs = reader.anchor(mention.id)?.refs ?? []
        let lines = reader.lineLabel(for: refs)
        return lines.isEmpty ? "\(mention.phrase), opens original" : "\(mention.phrase), opens original, \(lines)"
    }

    private func restChip(_ reader: FirstMateSkimReader) -> some View {
        let isOpen = presented?.source == .rest
        let title = Text("Rest of the original")
            .font(.footnote.weight(.medium))
            .foregroundStyle(isOpen ? style.text : style.secondaryText)
        let kind = Text("Detail")
            .font(.caption)
            .foregroundStyle(style.tertiaryText)
        // Round like a capsule on one line, still tidy when large text wraps it.
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        return Button {
            open(refs: reader.restRefs, anchorID: nil, title: "Rest of the original", reader: reader, source: .rest)
        } label: {
            // One Text, so the kind wraps along with the title at large sizes.
            Text("\(title)  \(kind)")
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isOpen ? style.line : .clear, in: shape)
                .overlay {
                    shape.strokeBorder(
                        style.secondaryText.opacity(isOpen ? 0.6 : 0.45),
                        style: StrokeStyle(lineWidth: 1, dash: isOpen ? [] : [4, 3])
                    )
                }
            // A 44 pt target around a compact chip.
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rest of the original")
        .accessibilityValue(reader.restPeek)
        .accessibilityHint("Opens the original text")
        .accessibilityIdentifier("skim-rest-\(messageID)")
        .composerLayoutMeasurement(id: "skim-rest-chip", label: "Rest of the original")
        .popover(item: popoverBinding(.rest), attachmentAnchor: .rect(.bounds)) { request in
            excerpt(request, presentation: .popover)
        }
    }

    @ViewBuilder
    private func nextStep(_ step: FirstMateSkimReader.NextStep, index: Int, reader: FirstMateSkimReader) -> some View {
        switch step {
        case .ask(let tokens):
            // The dot sits a little above the baseline, level with lowercase letters.
            let lift = askDot * 0.2
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(style.attention)
                    .frame(width: askDot, height: askDot)
                    .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[.bottom] + lift }
                    .accessibilityHidden(true)
                linkedText(tokens, reader: reader, source: .nextStep(index), font: style.bodyFont, color: style.text)
            }
        case .next(let tokens):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Next")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(style.attention)
                linkedText(tokens, reader: reader, source: .nextStep(index), font: style.bodyFont, color: style.text)
            }
        }
    }

    // MARK: - Full reply

    private func fullReplyBody(_ reader: FirstMateSkimReader) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let highlighted = state.highlights(for: messageID)
            if highlighted.isEmpty {
                fullReply()
                    .composerLayoutMeasurement(id: "skim-full-reply")
            } else {
                SkimSegmentedReply(messageID: messageID, reader: reader, highlighted: highlighted, style: style)
                    .composerLayoutMeasurement(id: "skim-segmented-reply")
            }
            footer(reader, showsFullReply: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footer(_ reader: FirstMateSkimReader, showsFullReply: Bool) -> some View {
        // Side by side normally; stacked at accessibility sizes so the count keeps its width.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return layout {
            Button(showsFullReply ? "Skim" : "Full reply") {
                state.toggleFullReply(messageID)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(style.accent)
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .contentShape(.rect)
            .fixedSize()
            .accessibilityLabel(showsFullReply ? "Show skim" : "Show full reply")
            .accessibilityIdentifier("skim-toggle-\(messageID)")
            .composerLayoutMeasurement(id: "skim-toggle", label: showsFullReply ? "Skim" : "Full reply")
            if let stats = reader.document.stats {
                Text("\(stats.sourceWords) words, skimmed to \(stats.skimWords)")
                    .font(.footnote)
                    .foregroundStyle(style.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .composerLayoutMeasurement(id: "skim-stats")
            }
        }
    }

    // MARK: - Excerpts

    private func openAnchor(_ id: String, reader: FirstMateSkimReader, source: SkimExcerptRequest.Source) {
        guard let anchor = reader.anchor(id) else { return }
        open(refs: anchor.refs, anchorID: id, title: anchor.label, reader: reader, source: source)
    }

    private func open(
        refs: [String],
        anchorID: String?,
        title: String,
        reader: FirstMateSkimReader,
        source: SkimExcerptRequest.Source
    ) {
        guard !refs.isEmpty else { return }
        presented = SkimExcerptRequest(reader: reader, refs: refs, anchorID: anchorID, title: title, source: source)
    }

    private func excerpt(_ request: SkimExcerptRequest, presentation: SkimExcerptView.Presentation) -> some View {
        SkimExcerptView(
            reader: request.reader,
            refs: request.refs,
            title: request.title,
            style: style,
            presentation: presentation,
            showInReply: {
                presented = nil
                state.showInReply(messageID: messageID, refs: request.refs, reader: request.reader)
            },
            close: { presented = nil }
        )
        .frame(width: presentation == .popover ? (request.reader.isWide(request.refs) ? 720 : 540) : nil)
    }

    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    private var sheetBinding: Binding<SkimExcerptRequest?> {
        Binding(
            get: { isRegularWidth ? nil : presented },
            set: { if $0 == nil { presented = nil } }
        )
    }

    private func popoverBinding(_ source: SkimExcerptRequest.Source) -> Binding<SkimExcerptRequest?> {
        Binding(
            get: { isRegularWidth && presented?.source == source ? presented : nil },
            set: { if $0 == nil, presented?.source == source { presented = nil } }
        )
    }
}

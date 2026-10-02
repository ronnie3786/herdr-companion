import AppKit
import SwiftUI

/// A long reply shown as its skim (One breath, tight): the linked sentence, a
/// caveat when something failed or is risky, the Rest of the original chip,
/// and the suggested next step as the last line. Full reply is one click away.
/// Without a ready, valid skim this is exactly the full reply.
struct SkimmableReply<FullReply: View>: View {
    let messageID: String
    let reply: String
    let skim: FirstMateSkim?
    var style: SkimReplyStyle = .chat
    @ViewBuilder let fullReply: () -> FullReply

    @Environment(\.skimDisplayState) private var sharedState
    @Environment(\.skimScrollTo) private var scrollTo
    @Environment(\.skimReplyContext) private var replyContext
    @Environment(\.chatProsePalette) private var palette
    @Environment(\.colorScheme) private var scheme
    @Environment(\.herdrFontScale) private var fontScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var localState = SkimDisplayState()
    @State private var interactions = SkimInteractionHolder()
    /// Nil until the reply first appears: a skim already there shows at once.
    @State private var showsSkim: Bool?
    /// A skim that landed mid-read, waiting for the reader to move on.
    @State private var deferred = false
    @State private var hovering = false
    @State private var cardOpen = false
    @State private var rowProbe = SkimViewProbe()
    @State private var restProbe = SkimViewProbe()

    private var state: SkimDisplayState { sharedState ?? localState }

    var body: some View {
        let reader = FirstMateSkimReader.cached(skim: skim, reply: reply, owner: messageID)
        let usable = reader != nil && (showsSkim ?? true)
        VStack(alignment: .leading, spacing: 0) {
            if let reader, usable, !state.showsFullReply(messageID) {
                skimBody(reader, interaction: interaction(for: reader))
            } else if let reader, usable, let refs = state.revealedRefs(messageID) {
                revealedReply(reader, highlighted: Set(refs))
            } else {
                fullReply()
            }
            if let reader, usable {
                if let context = replyContext, context.messageID == messageID, !reader.actions.isEmpty {
                    SkimReplyActionsView(actions: reader.actions, context: context, state: state)
                        .padding(.top, 10)
                }
                footer(reader)
                    .padding(.top, 8)
            }
        }
        .background(SkimViewProbeView(probe: rowProbe))
        .onHover { inside in
            hovering = inside
            if !inside { swapIfIdle() }
        }
        .onAppear { if showsSkim == nil { showsSkim = reader != nil } }
        .onChange(of: reader != nil) { _, ready in
            if ready {
                deferred = true
                swapIfIdle()
            } else {
                showsSkim = false
                deferred = false
            }
        }
        .task(id: deferred) {
            // A skim that landed mid-read waits for the pointer, a selection,
            // or an open card to leave this reply, then swaps in without motion.
            while deferred, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                swapIfIdle()
            }
        }
    }

    // MARK: - Skim

    private func skimBody(_ reader: FirstMateSkimReader, interaction: SkimInteraction) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SkimTextView(tokens: reader.sentence, interaction: interaction,
                         fontSize: style.sentenceSize, lineHeight: style.sentenceLineHeight)
                .accessibilityIdentifier("skim-sentence-\(messageID)")
            ForEach(Array(reader.caveats.enumerated()), id: \.offset) { _, caveat in
                HStack(alignment: .top, spacing: 10) {
                    Rectangle().fill(HerdrTheme.alert.opacity(0.7)).frame(width: 2)
                    SkimTextView(tokens: caveat, interaction: interaction, fontSize: style.lineSize,
                                 lineHeight: style.lineLineHeight, textColor: palette.secondaryText)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Heads-up: \(caveat.map(\.plainText).joined())")
            }
            if reader.restCount > 0 {
                restChip(reader, interaction: interaction)
            }
            ForEach(Array(reader.nextSteps.enumerated()), id: \.offset) { _, step in
                nextStep(step, interaction: interaction)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            ForEach(reader.document.anchors, id: \.id) { anchor in
                Button("\(anchor.label), opens original, \(reader.lineLabel(for: anchor.refs))") {
                    interaction.open(anchorID: anchor.id)
                }
            }
        }
    }

    private func restChip(_ reader: FirstMateSkimReader, interaction: SkimInteraction) -> some View {
        Button {
            if let view = restProbe.view { interaction.openRest(from: view) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Rest of the original")
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(palette.secondaryText)
                Text("Detail")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(palette.marker)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 24)
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.Radius.composer)
                    .strokeBorder(palette.separator, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .contentShape(.rect)
            .background(SkimViewProbeView(probe: restProbe))
        }
        .buttonStyle(.herdrPlain)
        .onHover { inside in
            if inside, let view = restProbe.view {
                interaction.showPreview(refs: reader.restRefs, hint: reader.restPeek, from: view)
            } else {
                interaction.hidePreview()
            }
        }
        .help(reader.restPeek)
        .accessibilityLabel("Rest of the original, \(reader.restPeek)")
        .accessibilityIdentifier("skim-rest-\(messageID)")
    }

    @ViewBuilder
    private func nextStep(_ step: FirstMateSkimReader.NextStep, interaction: SkimInteraction) -> some View {
        switch step {
        case .ask(let tokens):
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(HerdrTheme.attentionBadge)
                    .frame(width: 6, height: 6)
                    .padding(.top, (style.lineLineHeight * fontScale.rawValue - 6) / 2)
                    .accessibilityHidden(true)
                SkimTextView(tokens: tokens, interaction: interaction, fontSize: style.lineSize,
                             lineHeight: style.lineLineHeight)
            }
            .padding(.top, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Suggested next step: \(tokens.map(\.plainText).joined())")
        case .next(let tokens):
            HStack(alignment: .top, spacing: 10) {
                Text("Next")
                    .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                    .foregroundStyle(HerdrTheme.attentionBadge)
                    .padding(.top, 3 * fontScale.rawValue)
                SkimTextView(tokens: tokens, interaction: interaction, fontSize: style.lineSize,
                             lineHeight: style.lineLineHeight)
            }
            .padding(.top, 2)
        }
    }

    private func footer(_ reader: FirstMateSkimReader) -> some View {
        let showsFull = state.showsFullReply(messageID)
        return HStack(spacing: 12) {
            Button(showsFull ? "Skim" : "Full reply") {
                interactions.current?.closeAll()
                state.toggle(messageID)
            }
            .buttonStyle(.herdrPlain)
            .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
            .foregroundStyle(palette.accent)
            .accessibilityIdentifier("skim-toggle-\(messageID)")
            .accessibilityHint(showsFull ? "Shows the short version with links to the original" : "Shows the reply exactly as written")
            if let stats = reader.document.stats {
                Text(showsFull ? "\(stats.sourceWords) words" : "\(stats.sourceWords) words, skimmed to \(stats.skimWords)")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(palette.marker)
            }
        }
    }

    // MARK: - Full reply at the revealed blocks

    private func revealedReply(_ reader: FirstMateSkimReader, highlighted: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(reader.segments, id: \.id) { segment in
                Group {
                    if segment.kind == "rule" {
                        Rectangle().fill(palette.separator).frame(height: 1).padding(.vertical, 6)
                    } else {
                        PiMarkdownMessageView(source: reader.text(of: segment.id), isStreaming: false,
                                              id: "skim-\(messageID)-\(segment.id)", detectsPaneLinks: false)
                    }
                }
                .background {
                    // An outline that reaches past the text without changing its
                    // layout; a fill under code and tables drops them below 4.5:1
                    // over the dusk glass.
                    if highlighted.contains(segment.id) {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(palette.accent.opacity(0.55), lineWidth: 1.5)
                            .padding(.horizontal, -6)
                            .padding(.vertical, -4)
                    }
                }
                .id(SkimDisplayState.scrollID(messageID: messageID, segment: segment.id))
            }
        }
    }

    // MARK: - State

    private func interaction(for reader: FirstMateSkimReader) -> SkimInteraction {
        let interaction = interactions.interaction(messageID: messageID, reader: reader)
        interaction.colorScheme = scheme
        interaction.fontScale = fontScale
        interaction.reduceMotion = reduceMotion
        interaction.palette = palette
        let state = self.state
        let messageID = self.messageID
        let scrollTo = self.scrollTo
        let cardOpen = $cardOpen
        interaction.reveal = { refs in
            state.reveal(messageID, refs: refs)
            guard let first = refs.first, let scrollTo else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                scrollTo(SkimDisplayState.scrollID(messageID: messageID, segment: first))
            }
        }
        interaction.openStateChanged = { cardOpen.wrappedValue = $0 }
        return interaction
    }

    private func swapIfIdle() {
        guard deferred, !hovering, !cardOpen, !rowProbe.hasSelectionInside() else { return }
        deferred = false
        showsSkim = true
    }
}

enum SkimReplyStyle {
    case chat, column, hud

    var sentenceSize: CGFloat {
        switch self {
        case .chat: 15
        case .column: 13
        case .hud: 14
        }
    }

    var sentenceLineHeight: CGFloat {
        switch self {
        case .chat: 24
        case .column: 20
        case .hud: 22
        }
    }

    var lineSize: CGFloat { self == .chat ? 14 : 13 }
    var lineLineHeight: CGFloat { self == .chat ? 22 : 20 }
}

/// Skim or Full reply per message, remembered while its chat is open.
@MainActor
@Observable
final class SkimDisplayState {
    private(set) var fullReplyIDs: Set<String> = []
    private(set) var revealed: [String: [String]] = [:]
    private(set) var sentReplyIDs: Set<String> = []

    func didSendReply(for messageID: String) { sentReplyIDs.insert(messageID) }

    func showsFullReply(_ messageID: String) -> Bool { fullReplyIDs.contains(messageID) }

    func revealedRefs(_ messageID: String) -> [String]? { revealed[messageID] }

    func toggle(_ messageID: String) {
        revealed[messageID] = nil
        if fullReplyIDs.contains(messageID) { fullReplyIDs.remove(messageID) } else { fullReplyIDs.insert(messageID) }
    }

    /// Show in reply: the full reply, scrolled to and highlighting these blocks.
    func reveal(_ messageID: String, refs: [String]) {
        fullReplyIDs.insert(messageID)
        revealed[messageID] = refs
    }

    static func scrollID(messageID: String, segment: String) -> String { "skim-\(messageID)-\(segment)" }
}

extension EnvironmentValues {
    @Entry var skimDisplayState: SkimDisplayState? = nil
    /// Scrolls the enclosing transcript to a view id (Show in reply).
    @Entry var skimScrollTo: ((String) -> Void)? = nil
}

/// A quiet "Skimming…" for a reply whose skim is still being written.
struct SkimPendingLabel: View {
    let skim: FirstMateSkim?
    @Environment(\.chatProsePalette) private var palette

    var body: some View {
        if skim?.status == .pending {
            Text("Skimming…")
                .herdrFont(size: HerdrTheme.TextSize.caption)
                .foregroundStyle(palette.marker)
                .accessibilityLabel("Writing a short version of this reply")
        }
    }
}

@MainActor
final class SkimInteractionHolder {
    private(set) var current: SkimInteraction?

    func interaction(messageID: String, reader: FirstMateSkimReader) -> SkimInteraction {
        if let current, current.messageID == messageID {
            current.update(reader: reader)
            return current
        }
        let created = SkimInteraction(messageID: messageID, reader: reader)
        current = created
        return created
    }
}

/// Gives SwiftUI content an AppKit anchor for popovers, and lets a reply tell
/// whether the person has text selected inside it.
@MainActor
final class SkimViewProbe {
    weak var view: NSView?

    func hasSelectionInside() -> Bool {
        guard let view, let window = view.window, let textView = window.firstResponder as? NSTextView,
              textView.selectedRange().length > 0 else { return false }
        return view.convert(view.bounds, to: nil).intersects(textView.convert(textView.bounds, to: nil))
    }
}

struct SkimViewProbeView: NSViewRepresentable {
    let probe: SkimViewProbe

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        probe.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        probe.view = view
    }
}

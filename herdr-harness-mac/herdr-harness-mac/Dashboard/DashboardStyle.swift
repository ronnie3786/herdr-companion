import SwiftUI

/// Calm-UI tokens for Dashboard and Agent view. One color means "needs you";
/// everything else is a glyph plus a word in a quiet tone.
extension HerdrTheme {
    static let attention = warning
    /// `warning` at 8% over a card (`elevated`), #2B2728; body text on it stays above 9:1.
    static let attentionSurface = Color(.sRGB, red: 0x2B / 255, green: 0x27 / 255, blue: 0x28 / 255, opacity: 1)
    static let attentionEdge = warning.opacity(0.22)
    /// Status pills are 20pt tall with a 4pt radius.
    static let pillRadius = 4.0
    static let nowRadius = Radius.composer
    static let bubbleRadius = Radius.card
    static let composerRadius = Radius.composer
}

/// Page metrics for Dashboard and Builds (MonoCode's 20pt page gutter).
enum DashboardMetrics {
    static let pagePadding: CGFloat = 20
    static let cardGap: CGFloat = 12
}

/// The single mapping from a First Mate status to what the person sees.
struct FeatureStatusPresentation: Equatable {
    enum Tone: Equatable { case blocked, awaiting, working, quiet, done }

    let label: String
    let symbol: String
    let tone: Tone

    init(status: String, awaitingTurn: Bool = false) {
        // An explicit blocked status outranks a parked-turn flag, so a
        // contradictory payload cannot conceal an intervention as Your turn.
        if status == "blocked" {
            (label, symbol, tone) = ("Blocked", "exclamationmark.triangle.fill", .blocked)
            return
        }
        if awaitingTurn {
            (label, symbol, tone) = ("Your turn", "arrow.turn.down.left", .awaiting)
            return
        }
        switch status {
        case "awaiting_direction": (label, symbol, tone) = ("Needs you", "diamond.fill", .awaiting)
        case "running", "coordinating": (label, symbol, tone) = ("Working", "circle.lefthalf.filled", .working)
        case "recovering": (label, symbol, tone) = ("Recovering", "arrow.triangle.2.circlepath", .quiet)
        case "ready": (label, symbol, tone) = ("Ready to plan", "circle", .quiet)
        case "paused": (label, symbol, tone) = ("Paused", "pause.fill", .quiet)
        case "completed", "finished": (label, symbol, tone) = ("Complete", "checkmark.circle", .done)
        case "cancelled": (label, symbol, tone) = ("Cancelled", "xmark.circle", .quiet)
        default: (label, symbol, tone) = (AgentBoardProse.readable(status).capitalized, "circle", .quiet)
        }
    }

    /// Dashboard and Agent view always render on the app's forced dark chrome,
    /// so the pills use the agent HUD tokens exactly as First Mate's dark
    /// badges do.
    var color: Color {
        switch tone {
        case .blocked: FirstMateStatusColors.color(for: .blocked, scheme: .dark)
        case .awaiting: FirstMateStatusColors.color(for: .awaitingDirection, scheme: .dark)
        case .working: FirstMateStatusColors.color(for: .working, scheme: .dark)
        case .quiet: HerdrTheme.mist
        case .done: HerdrTheme.success
        }
    }
}

struct DashboardStatusPill: View {
    let status: String
    var awaitingTurn = false

    var body: some View {
        let presentation = FeatureStatusPresentation(status: status, awaitingTurn: awaitingTurn)
        Label(presentation.label, systemImage: presentation.symbol)
            .labelStyle(PillLabelStyle())
            .herdrFont(size: HerdrTheme.TextSize.caption, weight: .semibold)
            .foregroundStyle(presentation.color)
            .padding(.horizontal, 6)
            .frame(minHeight: 20)
            .background(presentation.color.opacity(0.12), in: .rect(cornerRadius: HerdrTheme.pillRadius))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.label)
    }

    private struct PillLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 5) {
                configuration.icon.imageScale(.small)
                configuration.title
            }
        }
    }
}

/// Icon and title on one baseline with a set gap (`.ft .acc`, row labels).
struct DashboardInlineLabelStyle: LabelStyle {
    var spacing: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}

/// Current focus: the one thing each feature is doing right now.
struct DashboardNowBlock: View {
    enum Style { case card, column }

    let stageTitle: String?
    let stageIndex: Int?
    var style: Style = .card

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("NOW")
                    .herdrFont(size: HerdrTheme.TextSize.micro, weight: .semibold)
                    .tracking(0.8)
                    .foregroundStyle(HerdrTheme.accent)
                Spacer(minLength: 4)
                if let stageIndex, stageIndex > 0 {
                    Text("Stage \(stageIndex)")
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .monospacedDigit()
                        .foregroundStyle(HerdrTheme.tertiaryText)
                }
            }
            Text(stageTitle.map(AgentBoardProse.decodeEntities) ?? "No active stage")
                .herdrFont(size: HerdrTheme.TextSize.body, weight: .medium)
                .foregroundStyle(stageTitle == nil ? HerdrTheme.tertiaryText : HerdrTheme.primaryText)
                // One line everywhere, so card and column tab bars line up.
                .lineLimit(1, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(stageTitle ?? "")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(HerdrTheme.insetFill, in: .rect(cornerRadius: HerdrTheme.nowRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now: \(stageTitle ?? "No active stage")\(stageIndex.map { ", stage \($0)" } ?? "")")
    }
}

/// A compact segmented control that keeps white-on-lavender contrast out of
/// the picture: the selected segment is a raised surface, not a tint.
struct DashboardSegmented<Value: Hashable>: View {
    struct Segment: Identifiable {
        let value: Value
        let title: String
        let count: Int?
        var id: Value { value }
    }

    @Binding var selection: Value
    let segments: [Segment]
    let accessibilityLabel: String

    var body: some View {
        // MonoCode's `.tabs6`: 24pt tabs, the selected one on a 10% wash.
        HStack(spacing: 1) {
            ForEach(segments) { segment in
                let selected = segment.value == selection
                Button { selection = segment.value } label: {
                    HStack(spacing: 6) {
                        Text(segment.title)
                            .foregroundStyle(selected ? HerdrTheme.primaryText : HerdrTheme.tertiaryText)
                        if let count = segment.count {
                            Text("\(count)").monospacedDigit()
                                .herdrFont(size: HerdrTheme.TextSize.caption)
                                .foregroundStyle(HerdrTheme.tertiaryText)
                        }
                    }
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .padding(.horizontal, 10)
                    .frame(height: HerdrTheme.ControlHeight.small)
                    .background(selected ? HerdrTheme.selectedFill : .clear, in: .rect(cornerRadius: HerdrTheme.Radius.control))
                    .frame(minHeight: HerdrTheme.minHitTarget)
                    .contentShape(.rect)
                }
                .buttonStyle(.herdrPlain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Static placeholder shapes. No shimmer or spinner.
struct DashboardSkeletonBar: View {
    var width: CGFloat? = nil
    var height: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(HerdrTheme.chipFill)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .accessibilityHidden(true)
    }
}

/// Small uppercase section label (GOAL, AGENTS, JOURNAL).
struct DashboardMicroLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .herdrFont(size: HerdrTheme.TextSize.micro, weight: .semibold)
            .tracking(0.6)
            .foregroundStyle(HerdrTheme.tertiaryText)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A quiet icon button with a real hit target and a tooltip.
struct DashboardIconButton: View {
    let title: String
    let systemImage: String
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        Button(title, systemImage: systemImage, action: action)
            .buttonStyle(HerdrIconButtonStyle())
            .help(help ?? title)
    }
}

/// Opens the shared project/manual session form from either dashboard.
struct DashboardCreateFeatureMenu<Label: View>: View {
    let model: HerdrAppModel
    let shell: HerdrShellState
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button {
            shell.showFirstMateStart()
            shell.show(.firstMate, model: model)
        } label: { label() }
        .help("Start a new First Mate session")
    }
}

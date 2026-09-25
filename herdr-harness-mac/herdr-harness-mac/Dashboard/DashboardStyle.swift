import SwiftUI

/// Calm-UI tokens for Dashboard and Agent view. One color means "needs you";
/// everything else is a glyph plus a word in a quiet tone.
extension HerdrTheme {
    static let attention = warning
    /// `warning` at 10% over `elevated`; body text on it stays above 9:1.
    static let attentionSurface = Color(.sRGB, red: 0x3B / 255, green: 0x39 / 255, blue: 0x42 / 255, opacity: 1)
    static let attentionEdge = warning.opacity(0.4)
    static let pillRadius = 6.0
    static let nowRadius = 9.0
    static let bubbleRadius = 14.0
    static let composerRadius = 11.0
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
            .herdrFont(.subheadline, weight: .semibold)
            .foregroundStyle(presentation.color)
            .padding(.horizontal, 7).padding(.vertical, 2)
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

/// Current focus: the one thing each feature is doing right now.
struct DashboardNowBlock: View {
    enum Style { case card, column }

    let stageTitle: String?
    let stageIndex: Int?
    var style: Style = .card

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("NOW")
                    .herdrFont(size: 10, weight: .bold)
                    .tracking(0.8)
                    .foregroundStyle(HerdrTheme.accent)
                Spacer(minLength: 4)
                if let stageIndex, stageIndex > 0 {
                    Text("Stage \(stageIndex)")
                        .herdrFont(.subheadline, monospacedDigit: true)
                        .foregroundStyle(HerdrTheme.muted)
                }
            }
            Text(stageTitle.map(AgentBoardProse.decodeEntities) ?? "No active stage")
                .herdrFont(.body, weight: .medium)
                .foregroundStyle(stageTitle == nil ? HerdrTheme.muted : HerdrTheme.text)
                // Columns keep one line so their tab bars line up and never move.
                .lineLimit(style == .card ? 2 : 1, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(stageTitle ?? "")
        }
        .padding(.horizontal, style == .card ? 12 : 10)
        .padding(.vertical, 8)
        .background(HerdrTheme.surface, in: .rect(cornerRadius: HerdrTheme.nowRadius))
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
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                let selected = segment.value == selection
                Button { selection = segment.value } label: {
                    HStack(spacing: 5) {
                        Text(segment.title)
                        if let count = segment.count {
                            Text("\(count)").monospacedDigit()
                                .foregroundStyle(selected ? HerdrTheme.mist : HerdrTheme.muted)
                        }
                    }
                    .herdrFont(.callout, weight: selected ? .semibold : .regular)
                    .foregroundStyle(selected ? HerdrTheme.text : HerdrTheme.mist)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(selected ? HerdrTheme.surface : .clear, in: .rect(cornerRadius: HerdrTheme.pillRadius))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(HerdrTheme.input, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .overlay { RoundedRectangle(cornerRadius: HerdrTheme.compactRadius).stroke(HerdrTheme.separator) }
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
            .fill(HerdrTheme.surface.opacity(0.6))
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
            .herdrFont(size: 10, weight: .bold)
            .tracking(0.8)
            .foregroundStyle(HerdrTheme.muted)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A quiet icon button with a real hit target and a tooltip.
struct DashboardIconButton: View {
    let title: String
    let systemImage: String
    var help: String? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(isHovered ? HerdrTheme.text : HerdrTheme.muted)
            .frame(width: HerdrTheme.minHitTarget, height: HerdrTheme.minHitTarget)
            .contentShape(.rect)
            .onHover { isHovered = $0 }
            .help(help ?? title)
    }
}

/// Where a new First Mate feature can be created, shared by both screens.
struct DashboardCreateFeatureMenu<Label: View>: View {
    let model: HerdrAppModel
    let shell: HerdrShellState
    @ViewBuilder let label: () -> Label

    private var machines: [HerdrMachine] {
        model.machines.filter { model.firstMateConfiguration(machineID: $0.id) != nil }
    }

    var body: some View {
        if model.isDemoMode {
            Button { create("demo") } label: { label() }
        } else if machines.count == 1, let machine = machines.first {
            Button { create(machine.id) } label: { label() }
                .disabled(!model.canControl(machineID: machine.id))
                .help("Start a First Mate feature on \(machine.name)")
        } else {
            Menu {
                ForEach(machines) { machine in
                    Button(machine.name) { create(machine.id) }
                        .disabled(!model.canControl(machineID: machine.id))
                }
                if machines.isEmpty { Text("Connect a machine in Settings → Machines") }
            } label: { label() }
                .piChipMenu()
        }
    }

    private func create(_ machineID: String) {
        shell.createFirstMateFeature(on: machineID)
        shell.show(.firstMate, model: model)
    }
}

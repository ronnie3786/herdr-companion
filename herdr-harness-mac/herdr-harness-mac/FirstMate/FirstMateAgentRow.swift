import SwiftUI

/// One agent. `.detailed` (Agents tab) lists role, model and usage;
/// `.compact` (Overview, MonoCode's `.aagent`) is a 30pt line.
struct FirstMateAgentRow: View {
    enum Style { case detailed, compact }

    @Bindable var store: FirstMateStore
    let agent: FirstMateAssignment
    var style: Style = .detailed
    var showsDivider = true
    @Environment(\.colorScheme) private var scheme

    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }

    var body: some View {
        Button {
            Task {
                if agent.nativeSessionID != nil { await store.open(.session(agent)) }
                else if let retained = store.snapshot?.sessions(for: agent.id).last { await store.open(.history(retained)) }
            }
        } label: {
            switch style {
            case .compact: compact
            case .detailed: detailed
            }
        }
        .buttonStyle(.herdrPlain)
        .disabled(agent.nativeSessionID == nil && store.snapshot?.sessions(for: agent.id).isEmpty != false)
        .help(agent.nativeSessionID.map { "Open saved session \($0)" } ?? "The agent has not registered a saved session yet")
        .accessibilityIdentifier("first-mate-agent-\(agent.id)")
    }

    private var statusColor: Color {
        FirstMateStatusColors.color(for: agent.status, scheme: scheme) ?? palette.iconTint
    }

    private var statusSymbol: String {
        switch agent.status {
        case "running", "coordinating": "circle.dashed"
        case "completed", "complete", "passed", "finished": "checkmark.circle"
        case "failed", "error", "cancelled": "exclamationmark.circle"
        case "blocked", "awaiting_direction": "hand.raised"
        default: "circle"
        }
    }

    private var compact: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .herdrFont(size: 12)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            Text(agent.title)
                .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(agent.status.replacingOccurrences(of: "_", with: " ").capitalized)
                .herdrFont(size: HerdrTheme.TextSize.caption)
                .foregroundStyle(palette.tertiaryText)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 2)
        .frame(minHeight: 30)
        .contentShape(.rect)
        .overlay(alignment: .bottom) {
            if showsDivider { Rectangle().fill(palette.rowDivider).frame(height: 1) }
        }
    }

    private var detailed: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusSymbol)
                .herdrFont(size: 12)
                .foregroundStyle(statusColor)
                .padding(.top, 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.title)
                    .herdrFont(size: HerdrTheme.TextSize.body, weight: .medium)
                    .foregroundStyle(palette.text)
                Group {
                    Text("\(agent.role) · attempt \(agent.attempt) · revision \(agent.inputRevision)")
                    if let selection = agent.modelSelection {
                        Label(selection.compactDisplayName, systemImage: "cpu")
                            .help(selection.fullDisplayName)
                            .accessibilityLabel(selection.fullDisplayName)
                    }
                    if let subtree = agent.subtreeUsage, subtree != agent.usage {
                        Text("Own · \(FirstMateUsageFormatting.inlineSummary(agent.usage))")
                        Text("With descendants · \(FirstMateUsageFormatting.inlineSummary(subtree))")
                    } else {
                        Text(FirstMateUsageFormatting.inlineSummary(agent.usage))
                    }
                    if let count = store.snapshot?.sessions(for: agent.id).count, count > 1 {
                        Text("\(count) saved sessions")
                    }
                    if let verdict = agent.verdict, !verdict.isEmpty {
                        Text("Verdict: \(verdict.replacingOccurrences(of: "_", with: " "))")
                    }
                }
                .herdrFont(size: HerdrTheme.TextSize.caption)
                .monospacedDigit()
                .foregroundStyle(palette.tertiaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            FirstMateStatusLabel(status: agent.status)
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
        .overlay(alignment: .bottom) {
            if showsDivider { Rectangle().fill(palette.rowDivider).frame(height: 1) }
        }
    }
}

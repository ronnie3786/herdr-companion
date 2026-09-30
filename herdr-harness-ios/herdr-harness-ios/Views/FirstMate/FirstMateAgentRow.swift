import SwiftUI

/// One agent, as on the Mac: `.detailed` (Agents tab) lists role, model and
/// usage under the title; `.compact` (Overview) is one line with its status.
/// Rows are plain with a divider, never cards inside cards.
struct FirstMateAgentRow: View {
    enum Style { case detailed, compact }

    @Bindable var store: FirstMateStore
    let agent: FirstMateAssignment
    var style: Style = .detailed
    var showsDivider = true
    @Environment(\.firstMateHighlightedAssignment) private var highlighted

    private var sessions: [FirstMateSession] { store.snapshot?.sessions(for: agent.id) ?? [] }
    private var canOpen: Bool { agent.nativeSessionID != nil || !sessions.isEmpty }
    private var isHighlighted: Bool { highlighted == agent.id }

    var body: some View {
        Button(action: open) {
            Group {
                switch style {
                case .compact: compact
                case .detailed: detailed
                }
            }
            .padding(.horizontal, isHighlighted ? 10 : 0)
            .background(isHighlighted ? HerdrTheme.rowHighlightFill : .clear, in: .rect(cornerRadius: HerdrTheme.Radius.row))
            .overlay {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: HerdrTheme.Radius.row).strokeBorder(HerdrTheme.accent.opacity(0.6))
                }
            }
            .overlay(alignment: .bottom) {
                if showsDivider && !isHighlighted { Rectangle().fill(HerdrTheme.rowDivider).frame(height: 1) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.herdrPlain)
        .disabled(!canOpen)
        .accessibilityValue(isHighlighted ? "Mentioned agent" : "")
        .id(agent.id)
        .accessibilityHint(canOpen ? "Opens this agent's exact saved session and handoff history" : "This agent has not registered a saved session yet")
        .accessibilityIdentifier("first-mate-agent-\(agent.id)")
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

    private var statusColor: Color { FirstMateStatusLabel.color(for: agent.status) }

    private var compact: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol).font(.system(size: 13, weight: .medium)).foregroundStyle(statusColor)
                .accessibilityHidden(true)
            Text(agent.title).herdrFont(.subheadline, weight: .medium).foregroundStyle(HerdrTheme.primaryText)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(FirstMateStatusLabel.title(for: agent.status)).herdrFont(.footnote).foregroundStyle(HerdrTheme.tertiaryText)
                .lineLimit(1).fixedSize()
            if canOpen {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(HerdrTheme.iconTint)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: HerdrTheme.minHitTarget)
    }

    private var detailed: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusSymbol).font(.system(size: 13, weight: .medium)).foregroundStyle(statusColor)
                .padding(.top, 3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.title).herdrFont(.body, weight: .medium).foregroundStyle(HerdrTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    Text("\(agent.role.replacingOccurrences(of: "_", with: " ").capitalized) · attempt \(agent.attempt) · revision \(agent.inputRevision)")
                    if let selection = agent.modelSelection {
                        Label(selection.compactDisplayName, systemImage: "cpu")
                            .accessibilityLabel(selection.fullDisplayName)
                    }
                    if let subtree = agent.subtreeUsage, subtree != agent.usage {
                        Text("Own · \(FirstMateUsageFormatting.inlineSummary(agent.usage))")
                        Text("With descendants · \(FirstMateUsageFormatting.inlineSummary(subtree))")
                    } else {
                        Text(FirstMateUsageFormatting.inlineSummary(agent.usage))
                    }
                    if sessions.count > 1 { Text("\(sessions.count) saved sessions") }
                    if let verdict = agent.verdict, !verdict.isEmpty, verdict != "passed" {
                        Text("Verdict: \(verdict.replacingOccurrences(of: "_", with: " "))")
                    }
                }
                .herdrFont(.footnote).monospacedDigit().foregroundStyle(HerdrTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            FirstMateStatusLabel(status: agent.status)
        }
        .padding(.vertical, 10)
        .frame(minHeight: HerdrTheme.minHitTarget)
    }

    private func open() {
        Task {
            if agent.nativeSessionID != nil { await store.open(.session(agent)) }
            else if let session = sessions.last { await store.open(.history(session)) }
        }
    }
}

import SwiftUI

/// A First Mate status: an 11pt glyph and word in the status color
/// (MonoCode's `.st`). `.pill` is the title bar's status menu label.
struct FirstMateStatusLabel: View {
    enum Style { case plain, pill }

    let status: String
    var style: Style = .plain
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch style {
        case .plain:
            label
                .accessibilityLabel(title)
        case .pill:
            HStack(spacing: 5) {
                label
                Image(systemName: "chevron.down")
                    .herdrFont(size: HerdrTheme.TextSize.micro, weight: .semibold)
                    .foregroundStyle(HerdrTheme.iconTint)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(height: HerdrTheme.ControlHeight.small)
            .background(HerdrTheme.selectedFill, in: .rect(cornerRadius: HerdrTheme.Radius.control))
            .frame(minHeight: HerdrTheme.minHitTarget)
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .imageScale(.small)
            Text(title)
        }
        .herdrFont(size: HerdrTheme.TextSize.caption, weight: style == .pill ? .medium : .regular)
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
    }

    private var title: String {
        switch status {
        case "awaiting_direction": "Your direction"
        case "running", "coordinating": "Working"
        case "completed", "complete": "Complete"
        case "ready": "Ready to plan"
        case "recovering": "Recovering"
        default: status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var symbol: String {
        switch status {
        case "awaiting_direction", "blocked", "recovering": "hand.raised"
        case "unverified": "exclamationmark.triangle"
        case "running", "coordinating": "circle.dashed"
        case "completed", "complete", "passed": "checkmark.circle"
        case "paused": "pause.circle"
        case "cancelled", "failed", "error": "exclamationmark.circle"
        default: "circle"
        }
    }

    private var color: Color {
        if let mapped = FirstMateStatusColors.color(for: status, scheme: scheme) {
            return mapped
        }
        // The theme's status roles resolve to deepened hues in light.
        switch status {
        case "paused", "recovering", "unverified": return HerdrTheme.warning
        case "completed", "complete", "passed": return HerdrTheme.success
        case "failed", "error", "cancelled": return HerdrTheme.alert
        default: return HerdrTheme.tertiaryText
        }
    }
}

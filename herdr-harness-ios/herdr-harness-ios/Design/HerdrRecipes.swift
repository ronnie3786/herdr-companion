import SwiftUI

// Static fills and one-pixel rules. No live materials, per-row effects, or
// hover tracking. Pressed controls change their fill, not reading-text opacity.
extension View {
    func herdrCard(
        radius: CGFloat = HerdrTheme.Radius.card,
        fill: Color = HerdrTheme.cardFill, outline: Color = HerdrTheme.outline
    ) -> some View {
        modifier(HerdrOutlinedFill(radius: radius, fill: fill, outline: outline))
    }

    func herdrPanel(fill: Color = HerdrTheme.base) -> some View {
        herdrCard(radius: HerdrTheme.Radius.panel, fill: fill)
    }

    func herdrField(focused: Bool = false) -> some View {
        herdrCard(radius: HerdrTheme.Radius.control, fill: HerdrTheme.fieldFill,
                  outline: focused ? HerdrTheme.focusOutline : HerdrTheme.outline)
    }

    func herdrPlaceholder(_ text: String, isVisible: Bool, alignment: Alignment = .leading) -> some View {
        overlay(alignment: alignment) {
            if isVisible {
                Text(text)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    func herdrHairline(_ edge: Edge, color: Color = HerdrTheme.hairline) -> some View {
        modifier(HerdrHairline(edge: edge, color: color))
    }

    func herdrRowBackground(
        selected: Bool, pressed: Bool = false, radius: CGFloat = HerdrTheme.Radius.row
    ) -> some View {
        background(selected || pressed ? HerdrTheme.rowHighlightFill : .clear,
                   in: .rect(cornerRadius: radius))
    }

    func herdrPill(height: CGFloat = HerdrTheme.ControlHeight.regular) -> some View {
        padding(.horizontal, 10)
            .frame(minHeight: height)
            .background(HerdrTheme.selectedFill, in: .capsule)
    }

    func herdrCompactHitTarget(visual: CGFloat) -> some View {
        frame(width: visual, height: visual)
            .frame(minWidth: HerdrTheme.minHitTarget, minHeight: HerdrTheme.minHitTarget)
            .contentShape(.rect)
    }
}

private struct HerdrOutlinedFill: ViewModifier {
    let radius: CGFloat
    let fill: Color
    let outline: Color
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(fill, in: .rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(HerdrTheme.rule(outline, contrast: contrast), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

private struct HerdrHairline: ViewModifier {
    let edge: Edge
    let color: Color
    @Environment(\.colorSchemeContrast) private var contrast

    private var alignment: Alignment {
        switch edge {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: alignment) {
            Rectangle().fill(HerdrTheme.rule(color, contrast: contrast))
                .frame(width: edge == .leading || edge == .trailing ? 1 : nil,
                       height: edge == .top || edge == .bottom ? 1 : nil)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

struct HerdrMicroLabel: View {
    let text: String
    var count: Int?
    var color: Color = HerdrTheme.tertiaryText

    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .herdrFont(size: HerdrTheme.TextSize.micro, weight: .semibold, relativeTo: .caption2)
                .tracking(0.6)
                .foregroundStyle(color)
            if let count { HerdrCountBadge(count: count, style: .quiet) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct HerdrCountBadge: View {
    enum Style { case accent, quiet }
    let count: Int
    var style: Style = .accent

    var body: some View {
        Text("\(count)")
            .herdrFont(.caption2, weight: .semibold)
            .monospacedDigit()
            .foregroundStyle(style == .accent ? HerdrTheme.onBadge : HerdrTheme.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minWidth: 20, minHeight: 20)
            .background(style == .accent ? HerdrTheme.badgeFill : HerdrTheme.selectedFill, in: .capsule)
    }
}

struct HerdrTabs<Value: Hashable>: View {
    enum Style { case segments, underline }
    struct Tab: Identifiable {
        let value: Value
        let title: String
        var count: Int?
        var accessibilityIdentifier: String?
        var id: Value { value }
    }

    @Binding var selection: Value
    let tabs: [Tab]
    var style: Style = .segments
    let accessibilityLabel: String
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        // At large text sizes the tabs scroll instead of truncating their names
        // or shrinking their text. Regular inspector tabs retain a 44pt bar.
        if dynamicType.isAccessibilitySize || style == .underline {
            ScrollView(.horizontal) { strip }
                .scrollIndicators(.hidden)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            strip
        }
    }

    private var strip: some View {
        HStack(spacing: style == .underline ? 16 : 1) {
            ForEach(tabs) { tab in
                let selected = selection == tab.value
                Button { selection = tab.value } label: {
                    HStack(spacing: 6) {
                        Text(tab.title).fixedSize(horizontal: true, vertical: false)
                        if let count = tab.count { HerdrCountBadge(count: count, style: .quiet) }
                    }
                    .herdrFont(.footnote, weight: selected ? .semibold : .regular)
                    .foregroundStyle(selected ? HerdrTheme.primaryText : HerdrTheme.tertiaryText)
                    .padding(.horizontal, style == .segments ? 10 : 0)
                    .padding(.vertical, 10)
                    .frame(maxWidth: style == .segments && !dynamicType.isAccessibilitySize ? .infinity : nil)
                    .frame(minWidth: HerdrTheme.minHitTarget, minHeight: HerdrTheme.ControlHeight.bar)
                    .herdrRowBackground(selected: selected && style == .segments)
                    .overlay(alignment: .bottom) {
                        if selected && style == .underline {
                            Rectangle().fill(HerdrTheme.primaryText).frame(height: 2)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.herdrPlain)
                .accessibilityLabel(tab.count.map { "\(tab.title), \($0)" } ?? tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier(tab.accessibilityIdentifier ?? "")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct HerdrPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HerdrEnabledLabel { configuration.label }
    }
}

private struct HerdrEnabledLabel<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.isEnabled) private var enabled
    var body: some View { content.opacity(enabled ? 1 : 0.42) }
}

extension ButtonStyle where Self == HerdrPlainButtonStyle {
    static var herdrPlain: HerdrPlainButtonStyle { HerdrPlainButtonStyle() }
}

struct HerdrIconButtonStyle: ButtonStyle {
    var visualSize: CGFloat = 32
    var isActive = false
    var tint: Color = HerdrTheme.iconTint
    var restingFill: Color = .clear

    func makeBody(configuration: Configuration) -> some View {
        HerdrEnabledLabel {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: 17))
                .foregroundStyle(isActive || configuration.isPressed ? HerdrTheme.primaryText : tint)
                .frame(width: visualSize, height: visualSize)
                .background(isActive || configuration.isPressed ? HerdrTheme.selectedFill : restingFill,
                            in: .rect(cornerRadius: HerdrTheme.Radius.control))
                .frame(minWidth: HerdrTheme.minHitTarget, minHeight: HerdrTheme.minHitTarget)
                .contentShape(.rect)
        }
    }
}

struct HerdrButtonStyle: ButtonStyle {
    enum Kind { case primary, outline, ghost }
    var kind: Kind = .outline
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        HerdrButtonBody(configuration: configuration, kind: kind, height: height)
    }
}

private struct HerdrButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: HerdrButtonStyle.Kind
    let height: CGFloat
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .herdrFont(size: height < 44 ? 14 : 15, weight: .semibold, relativeTo: .subheadline)
            .foregroundStyle(kind == .primary ? (enabled ? HerdrTheme.onPrimary : HerdrTheme.onPrimaryDisabled)
                             : HerdrTheme.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: height)
            .herdrCard(radius: HerdrTheme.Radius.control, fill: fill,
                       outline: kind == .outline ? HerdrTheme.outline : .clear)
            .frame(minWidth: HerdrTheme.minHitTarget, minHeight: HerdrTheme.minHitTarget)
            .contentShape(.rect)
            .opacity(kind != .primary && !enabled ? 0.42 : 1)
    }

    private var fill: Color {
        switch kind {
        case .primary: enabled ? HerdrTheme.primaryAction.opacity(configuration.isPressed ? 0.85 : 1) : HerdrTheme.primaryDisabled
        case .outline: configuration.isPressed && enabled ? HerdrTheme.hoverFill : .clear
        case .ghost: configuration.isPressed && enabled ? HerdrTheme.selectedFill : .clear
        }
    }
}

struct HerdrPrimarySquareButtonStyle: ButtonStyle {
    var fill: Color = HerdrTheme.primaryAction
    var visualSize: CGFloat = 36
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.labelStyle(.iconOnly)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(enabled ? HerdrTheme.onPrimary : HerdrTheme.onPrimaryDisabled)
            .frame(width: visualSize, height: visualSize)
            .background(enabled ? fill.opacity(configuration.isPressed ? 0.85 : 1) : HerdrTheme.primaryDisabled,
                        in: .rect(cornerRadius: HerdrTheme.Radius.control))
            .frame(minWidth: HerdrTheme.minHitTarget, minHeight: HerdrTheme.minHitTarget)
            .contentShape(.rect)
    }
}

struct HerdrRowButtonStyle: ButtonStyle {
    var tint: Color = HerdrTheme.secondaryText

    func makeBody(configuration: Configuration) -> some View {
        HerdrEnabledLabel {
            configuration.label
                .herdrFont(.caption, weight: .medium)
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .herdrCard(radius: HerdrTheme.Radius.row,
                           fill: configuration.isPressed ? HerdrTheme.rowHighlightFill : .clear)
                .frame(minWidth: HerdrTheme.minHitTarget, minHeight: HerdrTheme.minHitTarget)
                .contentShape(.rect)
        }
    }
}

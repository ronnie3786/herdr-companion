import SwiftUI

// Mono × Herdr component recipes. Each one is a flat fill plus at most one
// 1pt line: no shadows, blur, or hover tracking, so they are safe in long
// lists (see `PiChatChromeStyles.swift` for the transcript's performance rules).

extension View {
    /// A card: `cardFill` in a 12pt rounded rectangle with a 10% outline.
    func herdrCard(
        radius: CGFloat = HerdrTheme.Radius.card,
        fill: Color = HerdrTheme.cardFill,
        outline: Color = HerdrTheme.outline
    ) -> some View {
        modifier(HerdrOutlinedFill(radius: radius, fill: fill, outline: outline))
    }

    /// A floating panel (HUD, palette): 16pt radius, opaque `base`, 10% outline.
    func herdrPanel(fill: Color = HerdrTheme.base) -> some View {
        modifier(HerdrOutlinedFill(radius: HerdrTheme.Radius.panel, fill: fill, outline: HerdrTheme.outline))
    }

    /// A text field or search box: 4% fill, 10% outline, 6pt radius.
    func herdrField(focused: Bool = false) -> some View {
        modifier(HerdrOutlinedFill(
            radius: HerdrTheme.Radius.control,
            fill: HerdrTheme.fieldFill,
            outline: focused ? HerdrTheme.focusOutline : HerdrTheme.outline
        ))
    }

    /// A 1pt hairline along one edge (title bars, sidebar edges, section rules).
    /// A text field's placeholder in tertiary ink. AppKit draws a SwiftUI
    /// prompt in the field's own foreground color, so it would read like typed
    /// text; pass `prompt: Text("")` and draw it here instead.
    func herdrPlaceholder(_ text: String, isVisible: Bool, alignment: Alignment = .leading) -> some View {
        overlay(alignment: alignment) {
            if isVisible {
                Text(text)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    func herdrHairline(_ edge: Edge, color: Color = HerdrTheme.hairline) -> some View {
        overlay(alignment: edge.herdrAlignment) {
            Rectangle()
                .fill(color)
                .frame(
                    width: edge == .leading || edge == .trailing ? 1 : nil,
                    height: edge == .top || edge == .bottom ? 1 : nil
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Row and tab selection: 10% when selected, 5% when hovered, 6pt radius.
    func herdrRowBackground(
        selected: Bool,
        hovered: Bool = false,
        radius: CGFloat = HerdrTheme.Radius.control
    ) -> some View {
        background(
            selected ? HerdrTheme.selectedFill : hovered ? HerdrTheme.hoverFill : Color.clear,
            in: .rect(cornerRadius: radius)
        )
    }

    /// A 10% pill (model + effort, Steer, status menus).
    func herdrPill(height: CGFloat = HerdrTheme.ControlHeight.regular) -> some View {
        padding(.horizontal, 6)
            .frame(minHeight: height)
            .background(HerdrTheme.selectedFill, in: .rect(cornerRadius: HerdrTheme.Radius.control))
    }

    /// A `Menu` drawn as a flat icon button (title-bar and toolbar menus).
    func herdrIconMenu(visualSize: CGFloat = HerdrTheme.ControlHeight.regular, tint: Color = HerdrTheme.iconTint) -> some View {
        menuStyle(.button)
            .buttonStyle(HerdrIconButtonStyle(visualSize: visualSize, tint: tint))
            .menuIndicator(.hidden)
            .fixedSize()
    }

    /// Keeps a 28pt pointer target around a control drawn at 20–26pt.
    /// Apply inside a `Button`/`Menu` label, after the visual frame.
    func herdrCompactHitTarget(visual: CGFloat) -> some View {
        frame(width: visual, height: visual)
            .frame(minWidth: HerdrTheme.minHitTarget, minHeight: HerdrTheme.minHitTarget)
            .contentShape(Rectangle())
    }
}

private struct HerdrOutlinedFill: ViewModifier {
    let radius: CGFloat
    let fill: Color
    let outline: Color

    func body(content: Content) -> some View {
        content
            .background(fill, in: .rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(outline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

private extension Edge {
    var herdrAlignment: Alignment {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }
}

/// 10pt uppercase section label (GOAL, AGENTS, STAGED).
struct HerdrMicroLabel: View {
    let text: String
    var count: Int?
    var color: Color = HerdrTheme.tertiaryText

    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .herdrFont(size: HerdrTheme.TextSize.micro, weight: .semibold)
                .tracking(0.6)
                .foregroundStyle(color)
            if let count {
                HerdrCountBadge(count: count, style: .quiet)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A 16pt count capsule: lavender (Git sections) or a quiet 10% ink wash.
struct HerdrCountBadge: View {
    enum Style { case accent, quiet }

    let count: Int
    var style: Style = .accent

    var body: some View {
        Text("\(count)")
            .herdrFont(size: 9, weight: .semibold)
            .monospacedDigit()
            .foregroundStyle(style == .accent ? HerdrTheme.onBadge : HerdrTheme.secondaryText)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(style == .accent ? HerdrTheme.badgeFill : HerdrTheme.selectedFill, in: .capsule)
    }
}

/// SwiftUI's `.plain` without its press fade. On macOS `.plain` draws the
/// whole label, fills included, at 75% while the mouse is down and while a
/// menu is open, which drops text under 4.5:1 over the dusk glass. Disabled
/// labels still dim, to 42% like the other Herdr styles (disabled controls
/// are exempt from 4.5:1). Hit testing, focus and accessibility are
/// unchanged; rows show hover and selection in their own fills.
struct HerdrPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HerdrPlainButtonBody(label: configuration.label)
    }
}

private struct HerdrPlainButtonBody<Label: View>: View {
    let label: Label
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label.opacity(isEnabled ? 1 : 0.42)
    }
}

extension ButtonStyle where Self == HerdrPlainButtonStyle {
    /// `.plain` without the press fade; use it instead of `.plain`.
    static var herdrPlain: HerdrPlainButtonStyle { HerdrPlainButtonStyle() }
}

/// MonoCode's tab strips.
///
/// `.segments`: equal-width 24pt tabs in a row, the selected one on a 10%
/// wash (sidebar filters, title-bar filters). `.underline`: text tabs with a
/// 2pt ink rule under the selected one (inspectors, Agent view columns).
struct HerdrTabs<Value: Hashable>: View {
    enum Style { case segments, compactSegments, underline }

    struct Tab: Identifiable {
        let value: Value
        let title: String
        var count: Int?
        var accessibilityIdentifier: String?
        /// A tooltip, e.g. a machine's full name behind a short title.
        var help: String?
        /// VoiceOver's name when the visible title is abbreviated.
        var accessibilityLabel: String?
        var id: Value { value }
    }

    @Binding var selection: Value
    let tabs: [Tab]
    var style: Style = .segments
    var accessibilityLabel: String

    var body: some View {
        HStack(spacing: style == .underline ? 16 : 1) {
            ForEach(tabs) { tab in
                button(for: tab)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func button(for tab: Tab) -> some View {
        let selected = tab.value == selection
        Button { selection = tab.value } label: {
            label(for: tab, selected: selected)
        }
        .buttonStyle(.herdrPlain)
        .modifier(HerdrOptionalHelp(text: tab.help))
        .accessibilityLabel(tab.accessibilityLabel ?? tab.count.map { "\(tab.title), \($0)" } ?? tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(tab.accessibilityIdentifier ?? "")
    }

    @ViewBuilder
    private func label(for tab: Tab, selected: Bool) -> some View {
        let title = HStack(spacing: 6) {
            Text(tab.title)
                .lineLimit(1)
            if let count = tab.count {
                Text("\(count)")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .monospacedDigit()
                    .foregroundStyle(HerdrTheme.tertiaryText)
            }
        }
        .herdrFont(size: HerdrTheme.TextSize.small)
        .foregroundStyle(selected ? HerdrTheme.primaryText : HerdrTheme.tertiaryText)

        switch style {
        case .segments, .compactSegments:
            title
                .padding(.horizontal, 10)
                .frame(maxWidth: style == .segments ? .infinity : nil)
                .frame(height: HerdrTheme.ControlHeight.small)
                .herdrRowBackground(selected: selected)
                .frame(minHeight: HerdrTheme.minHitTarget)
                .contentShape(Rectangle())
        case .underline:
            title
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    if selected {
                        Rectangle()
                            .fill(HerdrTheme.primaryText)
                            .frame(height: 2)
                    }
                }
                .frame(minHeight: HerdrTheme.minHitTarget)
                .contentShape(Rectangle())
        }
    }
}

/// Flat icon button: a 20–26pt glyph box on a 28pt hit area, 50% ink,
/// 10% wash while hovered or active.
struct HerdrIconButtonStyle: ButtonStyle {
    var visualSize: CGFloat = HerdrTheme.ControlHeight.regular
    var isActive = false
    var tint: Color = HerdrTheme.iconTint
    /// MonoCode's `.tb`: a resting 10% wash (the composer's `+`).
    var restingFill: Color = .clear

    func makeBody(configuration: Configuration) -> some View {
        HerdrIconButtonBody(configuration: configuration, visualSize: visualSize, isActive: isActive, tint: tint, restingFill: restingFill)
    }
}

private struct HerdrIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let visualSize: CGFloat
    let isActive: Bool
    let tint: Color
    let restingFill: Color
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        // Like native toolbar icons, the glyph keeps its size at every text
        // size; the 26pt box and 28pt hit area never overflow their bar.
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 14))
            .foregroundStyle(isHovering || isActive ? HerdrTheme.primaryText : tint)
            .frame(width: visualSize, height: visualSize)
            .background(
                isHovering || isActive || configuration.isPressed
                    ? (restingFill == .clear ? HerdrTheme.selectedFill : HerdrTheme.focusOutline)
                    : restingFill,
                in: .rect(cornerRadius: HerdrTheme.Radius.control)
            )
            .frame(minWidth: HerdrTheme.minHitTarget, minHeight: HerdrTheme.minHitTarget)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.42)
            .onHover { isHovering = $0 }
    }
}

/// MonoCode buttons: `.primary` is lavender with a dark label; `.outline` is
/// a 10% ring with secondary text; `.ghost` is text only with a hover wash.
struct HerdrButtonStyle: ButtonStyle {
    enum Kind { case primary, outline, ghost }

    var kind: Kind = .outline
    var height: CGFloat = HerdrTheme.ControlHeight.large

    func makeBody(configuration: Configuration) -> some View {
        HerdrButtonBody(configuration: configuration, kind: kind, height: height)
    }
}

private struct HerdrButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: HerdrButtonStyle.Kind
    let height: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .herdrFont(size: height < HerdrTheme.ControlHeight.large ? HerdrTheme.TextSize.caption : HerdrTheme.TextSize.small, weight: .medium)
            .foregroundStyle(foreground)
            .padding(.horizontal, height < HerdrTheme.ControlHeight.large ? 8 : 10)
            .frame(minHeight: height)
            .background(fill, in: .rect(cornerRadius: HerdrTheme.Radius.control))
            .overlay {
                if kind == .outline {
                    RoundedRectangle(cornerRadius: HerdrTheme.Radius.control)
                        .strokeBorder(isHovering && isEnabled ? HerdrTheme.focusOutline : HerdrTheme.outline, lineWidth: 1)
                }
            }
            .frame(minHeight: HerdrTheme.minHitTarget)
            .contentShape(Rectangle())
            .opacity(opacity)
            .onHover { isHovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary: isEnabled ? HerdrTheme.onPrimary : HerdrTheme.onPrimaryDisabled
        case .outline, .ghost: isEnabled && isHovering ? HerdrTheme.primaryText : HerdrTheme.secondaryText
        }
    }

    /// Disabled outline and ghost buttons dim to 42%, like icon buttons
    /// (disabled controls are exempt from the 4.5:1 text rule). A press shows
    /// in the fill, never by fading the label, which would drop it under
    /// 4.5:1 over the dusk glass.
    private var opacity: Double {
        kind != .primary && !isEnabled ? 0.42 : 1
    }

    private var fill: Color {
        switch kind {
        case .primary:
            isEnabled ? HerdrTheme.primaryAction.opacity(configuration.isPressed ? 0.85 : 1) : HerdrTheme.primaryDisabled
        case .outline: (isHovering || configuration.isPressed) && isEnabled ? HerdrTheme.hoverFill : .clear
        case .ghost: (isHovering || configuration.isPressed) && isEnabled ? HerdrTheme.selectedFill : .clear
        }
    }
}

/// The composer's primary square: 26pt lavender with a dark glyph. Disabled is
/// lavender at 28% with the glyph at 55% (disabled controls are exempt from the
/// 4.5:1 text rule). `fill` overrides the lavender, e.g. alert while recording.
struct HerdrPrimarySquareButtonStyle: ButtonStyle {
    var fill: Color?
    var visualSize: CGFloat = HerdrTheme.ControlHeight.regular

    func makeBody(configuration: Configuration) -> some View {
        HerdrPrimarySquareBody(configuration: configuration, fill: fill, visualSize: visualSize)
    }
}

private struct HerdrPrimarySquareBody: View {
    let configuration: ButtonStyle.Configuration
    let fill: Color?
    let visualSize: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .herdrFont(size: 14, weight: .semibold)
            .foregroundStyle(isEnabled ? HerdrTheme.onPrimary : HerdrTheme.onPrimaryDisabled)
            .frame(width: visualSize, height: visualSize)
            .background(isEnabled ? (fill ?? HerdrTheme.primaryAction) : HerdrTheme.primaryDisabled, in: .rect(cornerRadius: HerdrTheme.Radius.control))
            .frame(minWidth: HerdrTheme.minHitTarget, minHeight: HerdrTheme.minHitTarget)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// MonoCode's `.btn-out.sm` for transcript rows: a 24pt outlined button with
/// a 28pt hit area and no hover tracking (transcript rows never observe the
/// pointer). Pressed dims to 70%.
struct HerdrRowButtonStyle: ButtonStyle {
    var tint: Color = HerdrTheme.secondaryText

    func makeBody(configuration: Configuration) -> some View {
        HerdrRowButtonBody(configuration: configuration, tint: tint)
    }
}

private struct HerdrRowButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(minHeight: HerdrTheme.ControlHeight.small)
            // Pressed shows a hover-weight fill rather than dimming the label,
            // which would drop it under 4.5:1 over the dusk glass.
            .background(configuration.isPressed ? HerdrTheme.hoverFill : .clear, in: .rect(cornerRadius: HerdrTheme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.Radius.control)
                    .strokeBorder(HerdrTheme.outline, lineWidth: 1)
            }
            .frame(minHeight: HerdrTheme.minHitTarget)
            .contentShape(Rectangle())
            // Disabled dims to 42%, like icon buttons.
            .opacity(isEnabled ? 1 : 0.42)
    }
}

/// A select trigger for a `Menu` (Settings model choices): a 26pt field-like
/// control with an icon, the current value and an up-down chevron.
struct HerdrSelectTrigger: View {
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .herdrFont(size: 12)
                    .foregroundStyle(HerdrTheme.iconTint)
                    .accessibilityHidden(true)
            }
            Text(title)
                .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                .foregroundStyle(HerdrTheme.primaryText)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .herdrFont(size: HerdrTheme.TextSize.micro, weight: .semibold)
                .foregroundStyle(HerdrTheme.iconTint)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: HerdrTheme.ControlHeight.regular)
        .background(HerdrTheme.insetFill, in: .rect(cornerRadius: HerdrTheme.Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.Radius.control)
                .strokeBorder(HerdrTheme.outline, lineWidth: 1)
        }
        .frame(minHeight: HerdrTheme.minHitTarget)
        .contentShape(Rectangle())
    }
}

extension View {
    /// An icon column beside text: `width` at 100%, growing with the text
    /// size so a larger glyph never runs into its label.
    func herdrIconSlot(width: CGFloat, height: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        modifier(HerdrIconSlot(width: width, height: height, alignment: alignment))
    }
}

private struct HerdrIconSlot: ViewModifier {
    let width: CGFloat
    let height: CGFloat?
    let alignment: Alignment
    @Environment(\.herdrFontScale) private var fontScale

    func body(content: Content) -> some View {
        content.frame(
            width: width * fontScale.rawValue,
            height: height.map { $0 * fontScale.rawValue },
            alignment: alignment
        )
    }
}

/// `.help` only when there is text, so a tab without its own tooltip keeps
/// its container's.
private struct HerdrOptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}

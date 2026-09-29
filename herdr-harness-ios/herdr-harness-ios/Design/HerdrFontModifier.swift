import SwiftUI
import UIKit

extension View {
    func herdrFont(
        size: CGFloat, weight: Font.Weight = .regular, monospaced: Bool = false,
        relativeTo style: Font.TextStyle = .body
    ) -> some View {
        modifier(HerdrFontModifier(size: size, weight: weight, monospaced: monospaced, style: style))
    }

    func herdrFont(
        _ style: Font.TextStyle, weight: Font.Weight? = nil, monospaced: Bool = false
    ) -> some View {
        let ramp = HerdrFont.ramp(style)
        return herdrFont(size: ramp.size, weight: weight ?? ramp.weight, monospaced: monospaced, relativeTo: style)
    }
}

private struct HerdrFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let monospaced: Bool
    let style: Font.TextStyle
    @Environment(\.dynamicTypeSize) private var dynamicType

    func body(content: Content) -> some View {
        content.font(.system(
            size: HerdrFont.scaledSize(size, relativeTo: style, dynamicType: dynamicType),
            weight: weight, design: monospaced ? .monospaced : .default
        ))
    }
}

enum HerdrFont {
    static func ramp(_ style: Font.TextStyle) -> (size: CGFloat, weight: Font.Weight) {
        switch style {
        case .largeTitle: (34, .semibold)
        case .title: (28, .semibold)
        case .title2: (22, .semibold)
        case .title3: (20, .semibold)
        case .headline: (HerdrTheme.TextSize.title, .semibold)
        case .body, .callout: (HerdrTheme.TextSize.body, .regular)
        case .subheadline: (HerdrTheme.TextSize.small, .regular)
        case .footnote, .caption: (HerdrTheme.TextSize.caption, .regular)
        case .caption2: (HerdrTheme.TextSize.micro, .regular)
        @unknown default: (HerdrTheme.TextSize.body, .regular)
        }
    }

    @MainActor
    static func scaledSize(_ size: CGFloat, relativeTo style: Font.TextStyle, dynamicType: DynamicTypeSize) -> CGFloat {
        UIFontMetrics(forTextStyle: style.uiKitTextStyle).scaledValue(
            for: size, compatibleWith: UITraitCollection(preferredContentSizeCategory: dynamicType.uiKitCategory)
        )
    }
}

private extension Font.TextStyle {
    var uiKitTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .body: .body
        case .callout: .callout
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }
}

private extension DynamicTypeSize {
    var uiKitCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

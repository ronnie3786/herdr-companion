import AppKit

/// One Mac definition of the Git change treatment.
///
/// The embedded Git page (`HerdrWebTheme`) and the native PR Review diff
/// (`PRReviewDiffTextView`) both derive their addition/removal backgrounds
/// from these values, so the two renderers cannot drift apart. The RGB
/// channels are the production Git segment's values; the three opacities are
/// the full row, line-number gutter, and changed-word emphasis levels.
enum HerdrDiffStyle {
    struct ChangeColor: Equatable, Sendable {
        let red: Int
        let green: Int
        let blue: Int

        var nsColor: NSColor {
            NSColor(
                srgbRed: CGFloat(red) / 255,
                green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255,
                alpha: 1
            )
        }

        var rgbLiteral: String {
            "rgb(\(red) \(green) \(blue)"
        }

        func css(opacity: Double) -> String {
            "\(rgbLiteral) / \(String(format: "%.2f", opacity)))"
        }
    }

    static let addition = ChangeColor(red: 46, green: 160, blue: 67)
    static let deletion = ChangeColor(red: 248, green: 81, blue: 73)

    static let lineOpacity = 0.30
    static let gutterOpacity = 0.42
    static let emphasisOpacity = 0.55

    static func change(for kind: String) -> ChangeColor? {
        switch kind {
        case "add": addition
        case "del": deletion
        default: nil
        }
    }

    /// Full-row background for an added or removed line.
    static func lineColor(for kind: String) -> NSColor? {
        change(for: kind)?.nsColor.withAlphaComponent(lineOpacity)
    }

    /// The stronger line-number gutter for an added or removed line.
    static func gutterColor(for kind: String) -> NSColor? {
        change(for: kind)?.nsColor.withAlphaComponent(gutterOpacity)
    }

    /// The changed-word background on an added or removed line.
    static func emphasisColor(for kind: String) -> NSColor? {
        change(for: kind)?.nsColor.withAlphaComponent(emphasisOpacity)
    }

    /// The `diffs-container` custom properties shared with the embedded Git page.
    static var cssVariables: String {
        """
        --diffs-bg-addition-override: \(addition.css(opacity: lineOpacity));
        --diffs-bg-addition-number-override: \(addition.css(opacity: gutterOpacity));
        --diffs-bg-addition-emphasis-override: \(addition.css(opacity: emphasisOpacity));
        --diffs-bg-deletion-override: \(deletion.css(opacity: lineOpacity));
        --diffs-bg-deletion-number-override: \(deletion.css(opacity: gutterOpacity));
        --diffs-bg-deletion-emphasis-override: \(deletion.css(opacity: emphasisOpacity));
        """
    }
}

import AppKit
import SwiftUI

/// One Mac definition of the Git change treatment.
///
/// The embedded Git page (`HerdrWebTheme`) and the native PR Review diff
/// (`PRReviewDiffTextView`) both derive their addition/removal backgrounds
/// from these values, so the two renderers cannot drift apart. The RGB
/// channels and the three opacities are the production Git segment's
/// `diffs-container` overrides for @pierre/diffs 1.3.2.
///
/// The library never paints those overrides directly. For a diff wrapped in
/// its `data-background` element — the Git segment's configuration — a
/// dark-scheme row resolves to `color-mix(in lab, <surface> 80%, <override>)`
/// and its line-number gutter to `color-mix(in lab, <surface> 85%,
/// <override>)`. Because `color-mix` premultiplies alpha, an override
/// contributes only `weight × opacity` of its colour over the surface, and a
/// gutter is resolved separately against the base rather than layered on the
/// already tinted row. `lineColor` and `gutterColor` reproduce those resolved
/// pixels over `HerdrTheme.graphite`; the changed-word emphasis stays a
/// translucent override painted over its row.
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

        /// sRGB components in the 0...1 range used by the colour conversion.
        var components: (red: Double, green: Double, blue: Double) {
            (Double(red) / 255, Double(green) / 255, Double(blue) / 255)
        }
    }

    static let addition = ChangeColor(red: 46, green: 160, blue: 67)
    static let deletion = ChangeColor(red: 248, green: 81, blue: 73)

    static let lineOpacity = 0.30
    static let gutterOpacity = 0.42
    static let emphasisOpacity = 0.55

    /// The dark-scheme `--mix-dark` surface weights @pierre/diffs 1.3.2 applies
    /// inside a `data-background` diff: a row keeps 80% of the surface, a
    /// line-number gutter 85%.
    static let lineSurfaceWeight = 0.80
    static let gutterSurfaceWeight = 0.85

    static func change(for kind: String) -> ChangeColor? {
        switch kind {
        case "add": addition
        case "del": deletion
        default: nil
        }
    }

    /// Full-row background for an added or removed line.
    static func lineColor(for kind: String) -> NSColor? {
        guard let change = change(for: kind) else { return nil }
        return resolvedColor(for: change, surfaceWeight: lineSurfaceWeight, opacity: lineOpacity)
    }

    /// The line-number gutter for an added or removed line. It is its own
    /// color-mix against the surface, not the row colour with another
    /// translucent layer stacked on top.
    static func gutterColor(for kind: String) -> NSColor? {
        guard let change = change(for: kind) else { return nil }
        return resolvedColor(for: change, surfaceWeight: gutterSurfaceWeight, opacity: gutterOpacity)
    }

    /// The changed-word background. The text system paints this translucent
    /// colour over `lineColor`, matching the production `[data-diff-span]`.
    static func emphasisColor(for kind: String) -> NSColor? {
        change(for: kind)?.nsColor.withAlphaComponent(emphasisOpacity)
    }

    /// The `diffs-container` custom properties shared with the embedded Git page.
    ///
    /// These stay as the library's input overrides: the browser performs the
    /// color-mix, and the native renderer resolves the same values above.
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

    // MARK: Resolving the production mix

    private struct Lab {
        var lightness: Double
        var aAxis: Double
        var bAxis: Double
    }

    /// The opaque surface both renderers tint. `HerdrWebTheme` gives the Git
    /// segment's `diffs-container` the same `HerdrTheme.graphite` value.
    private static var surface: (red: Double, green: Double, blue: Double) {
        let color = NSColor(HerdrTheme.graphite).usingColorSpace(.sRGB) ?? NSColor(HerdrTheme.graphite)
        return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    }

    /// Resolves `color-mix(in lab, <surface> surfaceWeight, rgba(change, opacity))`
    /// the way CSS does — premultiplied alpha in CIE Lab with a D50 white point
    /// — and composites the resulting translucent colour over the opaque
    /// surface, because the layer sits on the diff's own background.
    private static func resolvedColor(
        for change: ChangeColor,
        surfaceWeight: Double,
        opacity: Double
    ) -> NSColor {
        let baseRGB = surface
        let baseLab = lab(from: baseRGB)
        let changeLab = lab(from: change.components)
        let changeWeight = 1 - surfaceWeight
        let alpha = surfaceWeight + changeWeight * opacity
        let mixedLab = Lab(
            lightness: (surfaceWeight * baseLab.lightness
                + changeWeight * opacity * changeLab.lightness) / alpha,
            aAxis: (surfaceWeight * baseLab.aAxis + changeWeight * opacity * changeLab.aAxis) / alpha,
            bAxis: (surfaceWeight * baseLab.bAxis + changeWeight * opacity * changeLab.bAxis) / alpha
        )
        let mixed = rgb(from: mixedLab)
        return NSColor(
            srgbRed: CGFloat(alpha * mixed.red + (1 - alpha) * baseRGB.red),
            green: CGFloat(alpha * mixed.green + (1 - alpha) * baseRGB.green),
            blue: CGFloat(alpha * mixed.blue + (1 - alpha) * baseRGB.blue),
            alpha: 1
        )
    }

    // MARK: CIE Lab (D50) conversion

    // CSS Color 4 reference matrices; the Bradford adaptation is folded into
    // the D65/D50 pairs.
    private static let srgbToXYZD65: [Double] = [
        0.41239079926595934, 0.357584339383878, 0.1804807884018343,
        0.21263900587151027, 0.715168678767756, 0.07219231536073371,
        0.01933081871559182, 0.11919477979462598, 0.9505321522496607,
    ]
    private static let bradfordD65ToD50: [Double] = [
        1.0479298208405488, 0.022946793341019088, -0.05019222954313557,
        0.029627815688159344, 0.990434484573249, -0.01707382502938514,
        -0.009243058152591178, 0.015055144896577895, 0.7518742899580008,
    ]
    private static let bradfordD50ToD65: [Double] = [
        0.9554734527042182, -0.023098536874261423, 0.0632593086610217,
        -0.028369706963208136, 1.0099954580058226, 0.021041398966943008,
        0.012314001688319899, -0.020507696433477912, 1.3303659366080753,
    ]
    private static let xyzD65ToSRGB: [Double] = [
        3.2409699419045226, -1.537383177570094, -0.4986107602930034,
        -0.9692436362808796, 1.8759675015077202, 0.04155505740717559,
        0.05563007969699366, -0.20397695888897652, 1.0569715142428786,
    ]

    private static func multiply(
        _ matrix: [Double],
        _ vector: (Double, Double, Double)
    ) -> (Double, Double, Double) {
        (
            matrix[0] * vector.0 + matrix[1] * vector.1 + matrix[2] * vector.2,
            matrix[3] * vector.0 + matrix[4] * vector.1 + matrix[5] * vector.2,
            matrix[6] * vector.0 + matrix[7] * vector.1 + matrix[8] * vector.2
        )
    }

    private static func lab(from rgb: (red: Double, green: Double, blue: Double)) -> Lab {
        let linear = (srgbToLinear(rgb.red), srgbToLinear(rgb.green), srgbToLinear(rgb.blue))
        let d50 = multiply(bradfordD65ToD50, multiply(srgbToXYZD65, linear))
        let fx = labTransfer(d50.0 / 0.96422)
        let fy = labTransfer(d50.1)
        let fz = labTransfer(d50.2 / 0.82521)
        return Lab(lightness: 116 * fy - 16, aAxis: 500 * (fx - fy), bAxis: 200 * (fy - fz))
    }

    private static func rgb(from lab: Lab) -> (red: Double, green: Double, blue: Double) {
        let fy = (lab.lightness + 16) / 116
        let fx = fy + lab.aAxis / 500
        let fz = fy - lab.bAxis / 200
        let d50 = (
            labTransferInverse(fx) * 0.96422,
            labTransferInverse(fy),
            labTransferInverse(fz) * 0.82521
        )
        let linear = multiply(xyzD65ToSRGB, multiply(bradfordD50ToD65, d50))
        return (linearToSRGB(linear.0), linearToSRGB(linear.1), linearToSRGB(linear.2))
    }

    private static func srgbToLinear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }

    private static func labTransfer(_ value: Double) -> Double {
        value > 216.0 / 24389.0 ? pow(value, 1.0 / 3.0) : (841.0 / 108.0) * value + 4.0 / 29.0
    }

    private static func labTransferInverse(_ value: Double) -> Double {
        let cube = value * value * value
        return cube > 216.0 / 24389.0 ? cube : (value - 4.0 / 29.0) * 108.0 / 841.0
    }
}

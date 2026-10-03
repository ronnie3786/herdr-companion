import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// The red/green/yellow status mapping First Mate shares with the agent session
/// HUD. Dark appearance must equal the HUD tokens exactly; the First Mate light
/// appearance keeps those hues with enough contrast for its badge washes.
@Suite("First Mate status colors")
struct FirstMateStatusColorTests {
    @Test("Only the requested raw statuses map to a HUD kind",
          arguments: [
            ("blocked", FirstMateStatusColors.Kind.blocked),
            ("awaiting_direction", .awaitingDirection),
            ("running", .working),
            ("coordinating", .working),
          ])
    func rawStatuses(status: String, kind: FirstMateStatusColors.Kind) {
        #expect(FirstMateStatusColors.kind(for: status) == kind)
        #expect(FirstMateStatusColors.color(for: status, scheme: .dark) == FirstMateStatusColors.hudColor(for: kind))
    }

    @Test("Every dark color equals the corresponding agent session HUD token")
    func hudTokenEquality() {
        #expect(FirstMateStatusColors.color(for: .blocked, scheme: .dark) == HerdrTheme.alert)
        #expect(FirstMateStatusColors.color(for: .blocked, scheme: .dark) == AgentStatus.blocked.color)
        #expect(FirstMateStatusColors.color(for: .awaitingDirection, scheme: .dark) == HerdrTheme.signal)
        #expect(FirstMateStatusColors.color(for: .awaitingDirection, scheme: .dark) == AgentStatus.done.color)
        #expect(FirstMateStatusColors.color(for: .working, scheme: .dark) == HerdrTheme.working)
        #expect(FirstMateStatusColors.color(for: .working, scheme: .dark) == AgentStatus.working.color)
    }

    @Test("Blocked, waiting, and working stay visibly distinct in both appearances")
    func pairwiseDistinct() throws {
        for scheme in [ColorScheme.dark, .light] {
            let colors = try FirstMateStatusColors.Kind.allCases.map {
                try rgb(FirstMateStatusColors.color(for: $0, scheme: scheme))
            }
            for first in colors.indices {
                for second in colors.indices where second > first {
                    #expect(channelDistance(colors[first], colors[second]) > 0.15,
                            "\(scheme) colors \(first) and \(second) are too close")
                }
            }
        }
    }

    @Test("Unrelated statuses keep their existing fallbacks")
    func unrelatedFallbacks() {
        for status in ["paused", "recovering", "unverified", "completed", "complete", "passed", "cancelled", "failed", "error", "ready", "finished"] {
            #expect(FirstMateStatusColors.kind(for: status) == nil, "\(status) must not map to a HUD status color")
            #expect(FirstMateStatusColors.color(for: status, scheme: .dark) == nil)
            #expect(FirstMateStatusColors.color(for: status, scheme: .light) == nil)
        }

    }

    @Test("Light appearance keeps each HUD token's hue")
    func lightAppearanceHues() throws {
        for kind in FirstMateStatusColors.Kind.allCases {
            let hudHue = try hue(FirstMateStatusColors.hudColor(for: kind))
            let lightHue = try hue(FirstMateStatusColors.color(for: kind, scheme: .light))
            #expect(hueDistance(hudHue, lightHue) < 2,
                    "\(kind) should keep the HUD hue in light appearance")
        }
    }

    @Test("Badge and pill washes stay readable in both appearances",
          arguments: [ColorScheme.dark, .light])
    func compositedContrast(scheme: ColorScheme) throws {
        let surfaces = scheme == .dark ? darkSurfaces : lightSurfaces
        for kind in FirstMateStatusColors.Kind.allCases {
            let foreground = try rgb(FirstMateStatusColors.color(for: kind, scheme: scheme))
            for surface in surfaces {
                let background = try rgb(surface)
                for alpha in [0.09, 0.12] {
                    let washed = composite(foreground, alpha: alpha, over: background)
                    let contrast = contrastRatio(foreground, washed)
                    #expect(contrast >= 4.5,
                            "\(kind) in \(scheme) over a \(alpha) wash had \(contrast):1")
                }
            }
        }
    }

    private var lightSurfaces: [Color] {
        [FirstMatePalette(scheme: .light).surface,
         FirstMatePalette(scheme: .light).sidebar,
         FirstMatePalette(scheme: .light).background]
    }

    private var darkSurfaces: [Color] {
        [FirstMatePalette(scheme: .dark).surface,
         FirstMatePalette(scheme: .dark).sidebar,
         FirstMatePalette(scheme: .dark).background,
         HerdrTheme.elevated]
    }
}

// MARK: - Color math

/// The same sRGB component and contrast arithmetic the theme accessibility
/// tests use, extended with the wash compositing a status badge actually has.
private struct StatusColorRGB {
    let red: Double
    let green: Double
    let blue: Double
}

private func rgb(_ color: Color) throws -> StatusColorRGB {
    let converted = HerdrTheme.resolved(color)
    return StatusColorRGB(red: converted.redComponent, green: converted.greenComponent, blue: converted.blueComponent)
}

private func composite(_ foreground: StatusColorRGB, alpha: Double, over background: StatusColorRGB) -> StatusColorRGB {
    StatusColorRGB(
        red: foreground.red * alpha + background.red * (1 - alpha),
        green: foreground.green * alpha + background.green * (1 - alpha),
        blue: foreground.blue * alpha + background.blue * (1 - alpha)
    )
}

private func channelDistance(_ first: StatusColorRGB, _ second: StatusColorRGB) -> Double {
    let dRed = first.red - second.red
    let dGreen = first.green - second.green
    let dBlue = first.blue - second.blue
    return (dRed * dRed + dGreen * dGreen + dBlue * dBlue).squareRoot()
}

private func hue(_ color: Color) throws -> Double {
    let converted = HerdrTheme.resolved(color)
    var value: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    var alpha: CGFloat = 0
    converted.getHue(&value, saturation: &saturation, brightness: &brightness, alpha: &alpha)
    return Double(value) * 360
}

private func hueDistance(_ first: Double, _ second: Double) -> Double {
    let raw = abs(first - second).truncatingRemainder(dividingBy: 360)
    return min(raw, 360 - raw)
}

private func contrastRatio(_ first: StatusColorRGB, _ second: StatusColorRGB) -> Double {
    let a = relativeLuminance(first)
    let b = relativeLuminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

private func relativeLuminance(_ rgb: StatusColorRGB) -> Double {
    func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(rgb.red)
        + 0.7152 * linear(rgb.green)
        + 0.0722 * linear(rgb.blue)
}

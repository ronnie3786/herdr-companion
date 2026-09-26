import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// Mono × Herdr's 4.5:1 text floor, mirrored from the design study's
/// `check-contrast.mjs`: translucent fills are composited over the surface
/// they sit on before measuring, so the numbers match what is drawn.
@Suite("Comfortable reading contrast")
struct HerdrThemeAccessibilityTests {
    private typealias RGB = SIMD3<Double>

    // MARK: Dark (the whole app)

    @Test("Every text level stays readable on every opaque surface and inset fill")
    func textContrast() throws {
        let base = try rgb(HerdrTheme.base)
        let rail = try rgb(HerdrTheme.railBackground)
        let card = try over(HerdrTheme.cardFill, base)
        let surfaces: [(String, RGB)] = [
            ("base", base),
            ("rail", rail),
            ("card", card),
            ("field", try over(HerdrTheme.fieldFill, base)),
            ("selected on rail", try over(HerdrTheme.selectedFill, rail)),
            ("selected on base", try over(HerdrTheme.selectedFill, base)),
            ("folder group", try over(HerdrTheme.cardFill, rail)),
            ("selected in folder group", try over(HerdrTheme.selectedFill, try over(HerdrTheme.cardFill, rail))),
            ("hovered row", try over(HerdrTheme.hoverFill, rail)),
            ("bubble", try over(HerdrTheme.selectedFill, base)),
            ("code block", try over(HerdrTheme.codeFill, base)),
            ("chip in card", try over(HerdrTheme.chipFill, card)),
            ("NOW block", try over(HerdrTheme.insetFill, card)),
            ("attention box", try rgb(HerdrTheme.attentionSurface)),
            ("alias elevated", try rgb(HerdrTheme.elevated)),
            ("alias input", try rgb(HerdrTheme.input)),
            ("alias surface", try rgb(HerdrTheme.surface)),
            ("alias selection", try rgb(HerdrTheme.selection)),
            ("alias ink", try rgb(HerdrTheme.ink)),
            ("alias graphite", try rgb(HerdrTheme.graphite)),
        ]
        let text: [(String, Color)] = [
            ("primary", HerdrTheme.primaryText), ("prose", HerdrTheme.proseText),
            ("secondary", HerdrTheme.secondaryText), ("tertiary", HerdrTheme.tertiaryText),
            ("accent", HerdrTheme.accent), ("signal", HerdrTheme.signal), ("working", HerdrTheme.working),
            ("alert", HerdrTheme.alert), ("warning", HerdrTheme.warning), ("success", HerdrTheme.success),
            ("alias mist", HerdrTheme.mist), ("alias muted", HerdrTheme.muted), ("alias code", HerdrTheme.code),
        ]
        for (surfaceName, surface) in surfaces {
            for (textName, color) in text {
                let contrast = ratio(try rgb(color), surface)
                #expect(contrast >= 4.5, "\(textName) on \(surfaceName) was \(contrast):1")
            }
        }
    }

    @Test("Legible glass keeps text readable over the brightest desktop color")
    func legibleGlassContrast() throws {
        // The study's brightest wallpaper point: violet at 95% over deep indigo.
        let desktop = mix(RGB(132, 98, 222), 0.95, over: RGB(42, 29, 74))
        let base = try rgb(HerdrTheme.base)
        let sidebar = mix(base, HerdrTheme.Glass.sidebar, over: desktop)
        let pane = mix(base, HerdrTheme.Glass.pane, over: desktop)
        let hud = mix(base, HerdrTheme.Glass.hud, over: desktop)
        let checks: [(String, Color, RGB)] = [
            // Under glass the sidebar lifts its tertiary text to secondary.
            ("sidebar secondary", HerdrTheme.secondaryText, sidebar),
            ("selected sidebar secondary", HerdrTheme.secondaryText, try over(HerdrTheme.selectedFill, sidebar)),
            ("sidebar accent", HerdrTheme.accent, sidebar),
            ("pane tertiary", HerdrTheme.tertiaryText, pane),
            ("pane prose", HerdrTheme.proseText, pane),
            ("pane accent", HerdrTheme.accent, pane),
            ("HUD tertiary", HerdrTheme.tertiaryText, hud),
            ("HUD prose", HerdrTheme.proseText, hud),
        ]
        for (name, color, background) in checks {
            let contrast = ratio(try rgb(color), background)
            #expect(contrast >= 4.5, "\(name) was \(contrast):1")
        }
    }

    @Test("Primary, badge and native control labels have readable contrast")
    func primaryActionContrast() throws {
        let base = try rgb(HerdrTheme.base)
        #expect(ratio(try rgb(HerdrTheme.onPrimary), try rgb(HerdrTheme.primaryAction)) >= 4.5)
        #expect(ratio(try rgb(HerdrTheme.ink), try rgb(HerdrTheme.accent)) >= 4.5)
        #expect(ratio(RGB(255, 255, 255), try rgb(HerdrTheme.controlAccent)) >= 4.5)
        #expect(ratio(try rgb(HerdrTheme.text), try rgb(HerdrTheme.controlAccent)) >= 4.5)
        #expect(ratio(try rgb(HerdrTheme.onBadge), try over(HerdrTheme.badgeFill, base)) >= 4.5)
        #expect(ratio(try rgb(HerdrTheme.onAttentionBadge), try rgb(HerdrTheme.attentionBadge)) >= 4.5)
    }

    @Test("Diff code and line numbers stay readable on their row colors")
    func diffContrast() throws {
        let base = try rgb(HerdrTheme.base)
        let code = try rgb(HerdrTheme.inkSolid(0.80))
        let addRow = try over(HerdrTheme.diffAddRow, base)
        let removeRow = try over(HerdrTheme.diffRemoveRow, base)
        #expect(ratio(code, addRow) >= 4.5)
        #expect(ratio(code, removeRow) >= 4.5)
        #expect(ratio(try rgb(HerdrTheme.diffAddNumber), try over(HerdrTheme.diffAddGutter, addRow)) >= 4.5)
        #expect(ratio(try rgb(HerdrTheme.diffRemoveNumber), try over(HerdrTheme.diffRemoveGutter, removeRow)) >= 4.5)
        let hunk = try over(HerdrTheme.insetFill, base)
        #expect(ratio(try rgb(HerdrTheme.diffHunk), hunk) >= 4.5)
        for letter in [HerdrTheme.diffModified, HerdrTheme.diffUntracked, HerdrTheme.diffAdd, HerdrTheme.diffRemove] {
            #expect(ratio(try rgb(letter), try over(HerdrTheme.selectedFill, base)) >= 4.5)
        }
        for syntax in [HerdrTheme.Syntax.keyword, HerdrTheme.Syntax.callable, HerdrTheme.Syntax.string,
                       HerdrTheme.Syntax.type, HerdrTheme.Syntax.comment, HerdrTheme.Syntax.property] {
            #expect(ratio(try rgb(syntax), addRow) >= 4.5)
            #expect(ratio(try rgb(syntax), removeRow) >= 4.5)
            #expect(ratio(try rgb(syntax), try over(HerdrTheme.codeFill, base)) >= 4.5)
        }
    }

    // MARK: First Mate (dark and MonoCode light)

    @Test("First Mate text clears 4.5:1 on its surfaces in both appearances")
    func firstMateContrast() throws {
        for scheme in [ColorScheme.dark, .light] {
            let palette = FirstMatePalette(scheme: scheme)
            let background = try rgb(palette.background)
            let sidebar = try rgb(palette.sidebar)
            let card = try over(palette.cardFill, background)
            let surfaces: [(String, RGB)] = [
                ("background", background), ("sidebar", sidebar), ("surface", try rgb(palette.surface)),
                ("card", card), ("selected on sidebar", try over(palette.selectedFill, sidebar)),
                ("bubble", try over(palette.bubbleFill, background)),
                ("doc chip", try over(palette.chipFill, card)),
                ("inset in card", try over(palette.insetFill, card)),
            ]
            var text: [(String, Color)] = [
                ("text", palette.text), ("prose", palette.proseText), ("secondary", palette.secondaryText),
                ("tertiary", palette.tertiaryText), ("accent", palette.accent),
            ]
            for kind in FirstMateStatusColors.Kind.allCases {
                text.append(("status \(kind)", FirstMateStatusColors.color(for: kind, scheme: scheme)))
            }
            for (surfaceName, surface) in surfaces {
                for (textName, color) in text {
                    let contrast = ratio(try rgb(color), surface)
                    #expect(contrast >= 4.5, "\(scheme) \(textName) on \(surfaceName) was \(contrast):1")
                }
            }
        }
    }

    // MARK: Existing color systems

    @Test("Notes preserve readable body and error ink on every named color")
    func noteContrast() throws {
        for color in HerdrNoteColor.allCases {
            #expect(ratio(try rgb(color.ink), try rgb(color.fill)) >= 4.5)
            #expect(ratio(try rgb(HerdrNoteColor.errorInk), try rgb(color.fill)) >= 4.5)
        }
    }

    @Test("Chat color washes preserve secondary text and status contrast, including selection")
    func chatTabColorContrast() throws {
        for color in ChatTabColor.allCases {
            let surfaces = [color.rowBackground(),
                            color.rowBackground(hovering: true), color.rowBackground(selected: true)]
            for background in surfaces {
                for foreground in [HerdrTheme.text, HerdrTheme.mist, HerdrTheme.muted,
                                   HerdrTheme.working, HerdrTheme.success, HerdrTheme.alert] {
                    #expect(ratio(try rgb(foreground), try rgb(background)) >= 4.5,
                            "\(color.defaultLabel) must preserve reading contrast")
                }
            }
            #expect(ratio(try rgb(color.swatch), try rgb(color.rowBackground())) >= 4.5)
        }
    }

    // MARK: Helpers

    /// sRGB channels in 0...255; the color must be opaque.
    private func rgb(_ color: Color) throws -> RGB {
        let value = try #require(NSColor(color).usingColorSpace(.sRGB))
        #expect(value.alphaComponent > 0.999, "Measured an unexpectedly translucent color")
        return RGB(value.redComponent, value.greenComponent, value.blueComponent) * 255
    }

    /// A translucent `fill` composited over an opaque `background`.
    private func over(_ fill: Color, _ background: RGB) throws -> RGB {
        let value = try #require(NSColor(fill).usingColorSpace(.sRGB))
        let top = RGB(value.redComponent, value.greenComponent, value.blueComponent) * 255
        return mix(top, value.alphaComponent, over: background)
    }

    private func mix(_ top: RGB, _ alpha: Double, over bottom: RGB) -> RGB {
        top * alpha + bottom * (1 - alpha)
    }

    private func ratio(_ first: RGB, _ second: RGB) -> Double {
        let a = luminance(first)
        let b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func luminance(_ color: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            let value = channel / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.x) + 0.7152 * linear(color.y) + 0.0722 * linear(color.z)
    }
}

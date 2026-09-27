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

    @Test("Every text level stays readable on glass fills over the dusk's brightest points")
    @MainActor
    func duskGlassContrast() throws {
        let dusk = try brightestPixel(HerdrDusk.image)
        let hudDusk = try brightestPixel(HerdrDusk.trailingHalf)
        let haze = try brightestPixel(HerdrHaze.image)
        #expect(luminance(dusk) > luminance(RGB(40, 30, 70)), "The dusk rendered too dark: \(dusk)")
        let base = try rgb(HerdrTheme.base)
        let rail = try rgb(HerdrTheme.railBackground)
        let pane = mix(base, HerdrTheme.Glass.pane, over: dusk)
        // Cards, NOW blocks, chips and selected rows sit on every glass
        // surface, up to a selected row inside a card.
        let glassFills: [[Color]] = [
            [], [HerdrTheme.cardFill], [HerdrTheme.insetFill], [HerdrTheme.chipFill], [HerdrTheme.selectedFill],
            [HerdrTheme.cardFill, HerdrTheme.insetFill], [HerdrTheme.cardFill, HerdrTheme.chipFill],
            [HerdrTheme.cardFill, HerdrTheme.selectedFill],
        ]
        // Under the chat's haze band: transcript text, code, chips and bubbles.
        let chatFills: [[Color]] = [
            [], [HerdrTheme.cardFill], [HerdrTheme.insetFill], [HerdrTheme.chipFill], [HerdrTheme.selectedFill],
            [HerdrTheme.cardFill, HerdrTheme.insetFill],
        ]
        let surfaces: [(String, RGB, [[Color]])] = [
            ("sidebar", mix(rail, HerdrTheme.Glass.sidebar, over: dusk), glassFills),
            ("pane", pane, glassFills),
            ("HUD", mix(base, HerdrTheme.Glass.hud, over: hudDusk), glassFills),
            // The haze's brightest point stacked on the dusk's, which is
            // worse than anywhere the two actually overlap.
            ("chat haze", mix(haze, HerdrHazeBand.opacity, over: pane), chatFills),
        ]
        let text: [(String, Color)] = [
            ("tertiary", HerdrTheme.tertiaryText), ("secondary", HerdrTheme.secondaryText),
            ("prose", HerdrTheme.proseText), ("accent", HerdrTheme.accent), ("signal", HerdrTheme.signal),
            ("success", HerdrTheme.success), ("working", HerdrTheme.working), ("alert", HerdrTheme.alert),
            ("warning", HerdrTheme.warning),
        ]
        for (surfaceName, surface, fills) in surfaces {
            for stack in fills {
                var background = surface
                for fill in stack { background = try over(fill, background) }
                for (textName, color) in text {
                    let contrast = ratio(try rgb(color), background)
                    #expect(contrast >= 4.5, "\(textName) on \(surfaceName) with \(stack.count) fill(s) was \(contrast):1")
                }
            }
        }
    }

    @Test("Dark roles match First Mate's palette")
    func darkPaletteParity() throws {
        let palette = FirstMatePalette(scheme: .dark)
        for (name, role, token) in [("base", HerdrTheme.base, palette.background),
                                    ("secondary", HerdrTheme.secondaryText, palette.secondaryText),
                                    ("tertiary", HerdrTheme.tertiaryText, palette.tertiaryText),
                                    ("prose", HerdrTheme.proseText, palette.proseText),
                                    ("accent", HerdrTheme.accent, palette.accent)] {
            let difference = try rgb(role) - rgb(token)
            let largest = [difference.x, difference.y, difference.z].map(Swift.abs).max() ?? 0
            #expect(largest <= 1, "dark \(name) differs from First Mate's palette by \(difference)")
        }
    }

    /// The brightest sRGB pixel of an opaque image, by relative luminance.
    private func brightestPixel(_ image: NSImage) throws -> RGB {
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(drawn)
        var brightest = RGB(0, 0, 0), brightestLuminance = 0.0, isOpaque = true
        for index in stride(from: 0, to: pixels.count, by: 4) {
            isOpaque = isOpaque && pixels[index + 3] == 255
            let pixel = RGB(Double(pixels[index]), Double(pixels[index + 1]), Double(pixels[index + 2]))
            let value = luminance(pixel)
            if value > brightestLuminance { (brightest, brightestLuminance) = (pixel, value) }
        }
        #expect(isOpaque, "Glass backdrops must be opaque")
        return brightest
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

    // MARK: Light (First Mate's light appearance)

    @Test("The shared roles stay readable in First Mate's light appearance")
    func lightRoleContrast() throws {
        let base = try rgb(HerdrTheme.base, .light)
        let card = try over(HerdrTheme.cardFill, base, .light)
        let surfaces: [(String, RGB)] = [
            ("base", base),
            ("rail", try rgb(HerdrTheme.railBackground, .light)),
            ("card", card),
            ("field", try over(HerdrTheme.fieldFill, base, .light)),
            ("hovered row", try over(HerdrTheme.hoverFill, base, .light)),
            ("selected / bubble", try over(HerdrTheme.selectedFill, base, .light)),
            ("code block", try over(HerdrTheme.codeFill, base, .light)),
            ("chip in card", try over(HerdrTheme.chipFill, card, .light)),
            ("NOW block", try over(HerdrTheme.insetFill, card, .light)),
        ]
        let text: [(String, Color)] = [
            ("primary", HerdrTheme.primaryText), ("prose", HerdrTheme.proseText),
            ("secondary", HerdrTheme.secondaryText), ("tertiary", HerdrTheme.tertiaryText),
            ("accent", HerdrTheme.accent), ("signal", HerdrTheme.signal), ("working", HerdrTheme.working),
            ("alert", HerdrTheme.alert), ("warning", HerdrTheme.warning), ("success", HerdrTheme.success),
        ]
        for (surfaceName, surface) in surfaces {
            for (textName, color) in text {
                let contrast = ratio(try rgb(color, .light), surface)
                #expect(contrast >= 4.5, "light \(textName) on \(surfaceName) was \(contrast):1")
            }
        }
        // The lavender CTA takes a white label in light.
        let cta = ratio(try rgb(HerdrTheme.onPrimary, .light), try rgb(HerdrTheme.primaryAction, .light))
        #expect(cta >= 4.5, "light onPrimary on primary was \(cta):1")
        // The light roles match First Mate's palette, so shared chrome and
        // First Mate views agree.
        let palette = FirstMatePalette(scheme: .light)
        for (role, token) in [(HerdrTheme.base, palette.background), (HerdrTheme.tertiaryText, palette.tertiaryText),
                              (HerdrTheme.accent, palette.accent)] {
            let difference = try rgb(role, .light) - rgb(token, .light)
            let largest = [difference.x, difference.y, difference.z].map(Swift.abs).max() ?? 0
            #expect(largest <= 1, "light role differs from First Mate's palette by \(difference)")
        }
    }

    // MARK: Helpers

    /// sRGB channels in 0...255; the color must be opaque.
    private func rgb(_ color: Color, _ scheme: ColorScheme = .dark) throws -> RGB {
        let value = HerdrTheme.resolved(color, scheme: scheme)
        #expect(value.alphaComponent > 0.999, "Measured an unexpectedly translucent color")
        return RGB(value.redComponent, value.greenComponent, value.blueComponent) * 255
    }

    /// A translucent `fill` composited over an opaque `background`.
    private func over(_ fill: Color, _ background: RGB, _ scheme: ColorScheme = .dark) throws -> RGB {
        let value = HerdrTheme.resolved(fill, scheme: scheme)
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

import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Comfortable reading contrast")
struct HerdrThemeAccessibilityTests {
    @Test("Normal text remains readable on every standard surface")
    func textContrast() throws {
        let surfaces = [HerdrTheme.ink, HerdrTheme.graphite, HerdrTheme.elevated, HerdrTheme.input, HerdrTheme.selection]
        let foregrounds = [HerdrTheme.text, HerdrTheme.mist, HerdrTheme.muted, HerdrTheme.accent, HerdrTheme.code]
        for background in surfaces {
            for foreground in foregrounds {
                let contrast = try ratio(foreground, background)
                #expect(contrast >= 4.5, "Normal text contrast was \(contrast):1")
            }
        }
    }

    @Test("Primary action glyph has readable contrast")
    func primaryActionContrast() throws {
        #expect(try ratio(HerdrTheme.ink, HerdrTheme.primaryAction) >= 4.5)
        #expect(try ratio(HerdrTheme.ink, HerdrTheme.accent) >= 4.5)
        #expect(try ratio(.white, HerdrTheme.controlAccent) >= 4.5)
        #expect(try ratio(HerdrTheme.text, HerdrTheme.controlAccent) >= 4.5)
    }

    @Test("Notes preserve readable body and error ink on every named color")
    func noteContrast() throws {
        for color in HerdrNoteColor.allCases {
            #expect(try ratio(color.ink, color.fill) >= 4.5)
            #expect(try ratio(HerdrNoteColor.errorInk, color.fill) >= 4.5)
        }
    }

    @Test("Chat color washes preserve secondary text and status contrast, including selection")
    func chatTabColorContrast() throws {
        for color in ChatTabColor.allCases {
            let surfaces = [color.paneBackground, color.rowBackground(),
                            color.rowBackground(hovering: true), color.rowBackground(selected: true)]
            for background in surfaces {
                for foreground in [HerdrTheme.text, HerdrTheme.mist, HerdrTheme.muted,
                                   HerdrTheme.working, HerdrTheme.success, HerdrTheme.alert] {
                    #expect(try ratio(foreground, background) >= 4.5, "\(color.defaultLabel) must preserve reading contrast")
                }
            }
            #expect(try ratio(color.swatch, color.rowBackground()) >= 4.5)
        }
    }

    private func ratio(_ first: Color, _ second: Color) throws -> Double {
        let a = try luminance(first)
        let b = try luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func luminance(_ color: Color) throws -> Double {
        let rgb = try #require(NSColor(color).usingColorSpace(.sRGB))
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }
}

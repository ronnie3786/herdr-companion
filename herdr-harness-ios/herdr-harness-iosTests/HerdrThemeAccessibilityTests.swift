import SwiftUI
import Testing
@testable import herdr_harness_ios

@Suite("iOS dusk-glass contrast")
@MainActor
struct HerdrThemeAccessibilityTests {
    private let text: [(String, Color)] = [
        ("primary", HerdrTheme.primaryText), ("prose", HerdrTheme.proseText),
        ("secondary", HerdrTheme.secondaryText), ("tertiary", HerdrTheme.tertiaryText),
        ("accent", HerdrTheme.accent), ("signal", HerdrTheme.signal),
        ("working", HerdrTheme.working), ("alert", HerdrTheme.alert),
        ("warning", HerdrTheme.warning), ("success", HerdrTheme.success),
        ("your turn", HerdrTheme.attentionBadge),
    ]

    @Test("Every reading level clears 4.5:1 over the brightest dusk and haze")
    func textOverDusk() throws {
        let dusk = try ThemeRaster(HerdrDusk.image).brightest
        let haze = try ThemeRaster(HerdrHaze.image).brightest
        #expect(ThemeContrast.luminance(dusk) > ThemeContrast.luminance(.init(40, 30, 70)))
        let stacks: [[Color]] = [
            [], [HerdrTheme.cardFill], [HerdrTheme.fieldFill], [HerdrTheme.codeFill],
            [HerdrTheme.hoverFill], [HerdrTheme.selectedFill], [HerdrTheme.chipFill],
            [HerdrTheme.cardFill, HerdrTheme.insetFill], [HerdrTheme.cardFill, HerdrTheme.chipFill],
            [HerdrTheme.cardFill, HerdrTheme.selectedFill],
        ]
        for (surface, color, level) in [
            ("pane", HerdrTheme.base, HerdrTheme.Glass.pane),
            ("sidebar", HerdrTheme.railBackground, HerdrTheme.Glass.sidebar),
            ("hud", HerdrTheme.base, HerdrTheme.Glass.hud),
        ] {
            let pane = ThemeContrast.over(HerdrGlass.darkened(color, scheme: .dark).opacity(level), dusk)
            for withHaze in [false, true] {
                let background = withHaze ? haze * HerdrHazeBand.opacity + pane * (1 - HerdrHazeBand.opacity) : pane
                for stack in stacks {
                    let composed = stack.reduce(background) { ThemeContrast.over($1, $0) }
                    for (name, ink) in text {
                        let ratio = ThemeContrast.ratio(ThemeContrast.rgb(ink), composed)
                        #expect(ratio >= 4.5, "\(name), \(surface), haze=\(withHaze), fills=\(stack.count): \(ratio):1")
                    }
                }
            }
        }
    }

    @Test("Capsules, inline mentions, bubbles and reply controls retain contrast")
    func chatSurfaces() throws {
        let dusk = try ThemeRaster(HerdrDusk.image).brightest
        let haze = try ThemeRaster(HerdrHaze.image).brightest
        let pane = ThemeContrast.over(HerdrGlass.darkened(HerdrTheme.base, scheme: .dark).opacity(0.8), dusk)
        let chat = haze * HerdrHazeBand.opacity + pane * (1 - HerdrHazeBand.opacity)
        for (_, tint) in text {
            for outer in [Color.clear, HerdrTheme.cardFill, HerdrTheme.codeFill] {
                let capsule = [outer, HerdrTheme.codeFill, tint.opacity(0.11)]
                    .reduce(chat) { ThemeContrast.over($1, $0) }
                #expect(ThemeContrast.ratio(ThemeContrast.rgb(HerdrTheme.primaryText), capsule) >= 4.5)
            }
            let mention = ThemeContrast.over(tint.opacity(0.22), ThemeContrast.over(HerdrTheme.codeFill, chat))
            #expect(ThemeContrast.ratio(ThemeContrast.rgb(HerdrTheme.primaryText), mention) >= 4.5)
        }
        for fill in [HerdrTheme.codeFill, HerdrTheme.accent.opacity(0.2)] {
            for (_, ink) in text.prefix(4) {
                #expect(ThemeContrast.ratio(ThemeContrast.rgb(ink), ThemeContrast.over(fill, chat)) >= 4.5)
            }
        }
        for fill in [Color.clear, HerdrTheme.hoverFill, HerdrTheme.selectedFill, HerdrTheme.accent.opacity(0.16)] {
            #expect(ThemeContrast.ratio(ThemeContrast.rgb(HerdrTheme.accent), ThemeContrast.over(fill, chat)) >= 4.5)
        }
        for fill in [HerdrTheme.primaryAction, HerdrTheme.primaryAction.opacity(0.85)] {
            #expect(ThemeContrast.ratio(ThemeContrast.rgb(HerdrTheme.onPrimary), ThemeContrast.over(fill, chat)) >= 4.5)
        }
    }

    @Test("Working labels keep the Mac's 0.75 breathing floor on pressed and selected rows")
    func breathingFloor() throws {
        #expect(FirstMateBreathing.floor == 0.75)
        let dusk = try ThemeRaster(HerdrDusk.image).brightest
        let haze = try ThemeRaster(HerdrHaze.image).brightest
        for base in [HerdrTheme.base, HerdrTheme.railBackground] {
            let pane = ThemeContrast.over(HerdrGlass.darkened(base, scheme: .dark).opacity(0.8), dusk)
            for withHaze in [false, true] {
                let surface = withHaze ? haze * HerdrHazeBand.opacity + pane * (1 - HerdrHazeBand.opacity) : pane
                for fill in [Color.clear, HerdrTheme.rowHighlightFill, HerdrTheme.hoverFill, HerdrTheme.selectedFill] {
                    let background = ThemeContrast.over(fill, surface)
                    let ink = ThemeContrast.over(HerdrTheme.working.opacity(FirstMateBreathing.floor), background)
                    #expect(ThemeContrast.ratio(ink, background) >= 4.5)
                }
            }
        }
    }

    @Test("Legacy aliases retain readable opaque surfaces and unchanged layout metrics")
    func aliases() {
        for surface in [HerdrTheme.ink, HerdrTheme.graphite, HerdrTheme.elevated, HerdrTheme.input, HerdrTheme.surface] {
            for (_, ink) in text {
                #expect(ThemeContrast.ratio(ThemeContrast.rgb(ink), ThemeContrast.rgb(surface)) >= 4.5)
            }
        }
        #expect(HerdrTheme.text == HerdrTheme.primaryText)
        #expect(HerdrTheme.attention == HerdrTheme.attentionBadge)
        #expect(HerdrTheme.cardRadius == 16 && HerdrTheme.compactRadius == 10 && HerdrTheme.pagePadding == 18)
        #expect(HerdrTheme.minHitTarget == 44)
    }

    @Test("Increase Contrast uses 16% rules, without changing dark ink or colored edges")
    func increasedContrastRules() {
        for line in [HerdrTheme.hairline, HerdrTheme.rowDivider, HerdrTheme.outline, HerdrTheme.strongOutline, HerdrTheme.focusOutline] {
            #expect(HerdrTheme.rule(line, contrast: .increased) == HerdrTheme.inkFill(0.16))
            #expect(HerdrTheme.rule(line, contrast: .standard) == line)
        }
        #expect(HerdrTheme.rule(HerdrTheme.accent, contrast: .increased) == HerdrTheme.accent)
    }
}

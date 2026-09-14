import CoreGraphics
import Testing
@testable import herdr_harness_mac

@Suite("HUD chat sizing")
struct HerdrHudChatSizingTests {
    @Test("Size clamps to the screen budget, including other HUD surfaces")
    func screenBudget() {
        let size = HerdrHudChatSizing.constrained(CGSize(width: 4000, height: 4000),
                                                 screen: CGSize(width: 1200, height: 900), otherHeight: 100)
        #expect(size == CGSize(width: 1120, height: 720))
        let tiny = HerdrHudChatSizing.constrained(.zero, screen: CGSize(width: 400, height: 450), otherHeight: 40)
        #expect(tiny == CGSize(width: 320, height: 330))
    }

    @Test("Invalid saved dimensions fall back to defaults; normal dimensions keep usable minima")
    func invalidDimensions() {
        #expect(HerdrHudChatSizing.constrained(CGSize(width: CGFloat.nan, height: CGFloat.infinity), screen: .zero)
                == HerdrHudPlacement.expandedSize)
        #expect(HerdrHudChatSizing.constrained(CGSize(width: 100, height: 100), screen: .zero)
                == HerdrHudChatSizing.minimum)
    }

    @Test("Custom expanded sizes preserve the top-right anchor and never change the collapsed frame")
    func anchoredFrame() {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1200)
        let offset = CGSize(width: 10, height: 10)
        let original = HerdrHudPlacement.frame(isExpanded: true, visibleFrame: screen, topRightOffset: offset)
        let resized = HerdrHudPlacement.frame(isExpanded: true, visibleFrame: screen, topRightOffset: offset,
                                             expandedChatSize: CGSize(width: 720, height: 700))
        #expect(resized.size == CGSize(width: 800, height: 780))
        #expect(resized.maxX == original.maxX)
        #expect(resized.maxY == original.maxY)
        #expect(HerdrHudPlacement.frame(isExpanded: false, visibleFrame: screen, topRightOffset: offset,
                                       expandedChatSize: CGSize(width: 720, height: 700))
                == HerdrHudPlacement.frame(isExpanded: false, visibleFrame: screen, topRightOffset: offset))
    }

    @Test("Expanded compact-note scrolling uses the resized chat's actual height")
    func notesBudget() {
        let size = HerdrHudPlacement.compactNotesViewportSize(count: 100, isExpanded: true,
            visibleFrameHeight: 900, chipCount: 0, expandedChatSize: CGSize(width: 600, height: 620))
        #expect(size.height == 190)
    }
}

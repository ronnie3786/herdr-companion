import CoreGraphics
import Testing
@testable import herdr_harness_mac

@Suite("First Mate HUD placement geometry")
struct FirstMateHudPlacementGeometryTests {
    private typealias Geometry = FirstMateHudGeometry
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let cardSize = CGSize(width: 290, height: 104)
    private var rowClearance: CGFloat { Geometry.orbRowDrop - Geometry.orbSize / 2 - Geometry.cardGap / 2 }

    private func card(hugsFace: Bool = true) -> Geometry.Card {
        .init(size: cardSize, anchorY: -39, hugsFace: hugsFace)
    }

    private func orbRow(in output: Geometry.Output, count: Int = 6) -> CGRect {
        let half = Geometry.collapsedHalfWidth(orbCount: count)
        return CGRect(x: output.faceCenter.x - half, y: output.faceCenter.y + Geometry.orbRowDrop - Geometry.orbSize / 2,
                      width: half * 2, height: Geometry.orbSize)
    }

    private func expectCardWithinMargin(_ output: Geometry.Output) throws {
        let frame = try #require(output.cardFrame)
        let onScreen = CGRect(x: output.panelFrame.minX + frame.minX, y: output.panelFrame.maxY - frame.maxY,
                              width: frame.width, height: frame.height)
        #expect(onScreen.minX >= screen.minX + Geometry.margin - 0.5)
        #expect(onScreen.maxX <= screen.maxX - Geometry.margin + 0.5)
        #expect(onScreen.minY >= screen.minY + Geometry.margin - 0.5)
        #expect(onScreen.maxY <= screen.maxY - Geometry.margin + 0.5)
    }

    @Test("A collapsed latest-line card hugs the face above six orbs", arguments: [
        CGPoint(x: 400, y: 600), CGPoint(x: 720, y: 500), CGPoint(x: 1040, y: 500),
    ])
    func hugsTrailing(face: CGPoint) throws {
        let output = Geometry.layout(.init(faceCenter: face, visibleFrame: screen, column: .collapsed(orbCount: 6), card: card()))
        let frame = try #require(output.cardFrame)
        #expect(output.cardSide == .trailing)
        #expect(frame.minX - output.faceCenter.x == Geometry.faceRadius + Geometry.badgeReach + Geometry.cardGap)
        #expect(frame.maxY <= output.faceCenter.y + rowClearance)
        #expect(!frame.intersects(orbRow(in: output)))
        #expect(Geometry.face(panelFrame: output.panelFrame, faceInPanel: output.faceCenter) == face)
        try expectCardWithinMargin(output)
    }

    @Test("Near the right edge the latest line hugs the leading side")
    func hugsLeading() throws {
        let face = CGPoint(x: 1380, y: 600)
        let output = Geometry.layout(.init(faceCenter: face, visibleFrame: screen, column: .collapsed(orbCount: 6), card: card()))
        let frame = try #require(output.cardFrame)
        #expect(output.cardSide == .leading)
        #expect(frame.maxX == output.faceCenter.x - Geometry.faceRadius - Geometry.cardGap)
        #expect(frame.maxY <= output.faceCenter.y + rowClearance)
        #expect(!frame.intersects(orbRow(in: output)))
        // This input is one point outside the existing face-and-margin inset.
        #expect(Geometry.face(panelFrame: output.panelFrame, faceInPanel: output.faceCenter)
                == Geometry.clampFace(face, visibleFrame: screen))
        try expectCardWithinMargin(output)
    }

    @Test("Near the top the card falls back past the row, including side selection", arguments: [
        CGPoint(x: 400, y: 839), CGPoint(x: 1040, y: 839), CGPoint(x: 1380, y: 839),
    ])
    func topFallback(face: CGPoint) throws {
        let input = Geometry.Input(faceCenter: face, visibleFrame: screen, column: .collapsed(orbCount: 6), card: card())
        let output = Geometry.layout(input)
        var legacyInput = input
        legacyInput.card = card(hugsFace: false)
        #expect(output == Geometry.layout(legacyInput))
        let frame = try #require(output.cardFrame)
        let reach = Geometry.collapsedHalfWidth(orbCount: 6) + Geometry.cardGap
        if output.cardSide == .trailing {
            #expect(frame.minX - output.faceCenter.x == reach + Geometry.badgeReach)
        } else {
            #expect(output.faceCenter.x - frame.maxX == reach)
        }
        if face.x == 1040 {
            // The face-hugging start fits trailing here; the row-clearing one does not.
            #expect(output.cardSide == .leading)
        }
        #expect(frame.maxY > output.faceCenter.y + rowClearance)
        #expect(!frame.intersects(orbRow(in: output)))
        try expectCardWithinMargin(output)
    }

    @Test("Hugging works exactly at the top-margin boundary but falls back one point above", arguments: [823, 824])
    func topBoundary(faceY: Int) throws {
        let output = Geometry.layout(.init(faceCenter: CGPoint(x: 400, y: faceY), visibleFrame: screen,
                                           column: .collapsed(orbCount: 6), card: card()))
        let frame = try #require(output.cardFrame)
        let expectedReach: CGFloat = faceY == 823 ? 63 : 122
        #expect(frame.minX - output.faceCenter.x == expectedReach)
        #expect(!frame.intersects(orbRow(in: output)))
        if faceY == 823 {
            #expect(frame.maxY == output.faceCenter.y + rowClearance)
            #expect(output.panelFrame.maxY - frame.minY == screen.maxY - Geometry.margin)
        }
        try expectCardWithinMargin(output)
    }

    @Test("Non-hugging cards keep the original collapsed frames", arguments: [
        CGPoint(x: 400, y: 600), CGPoint(x: 720, y: 500),
    ])
    func legacyFrames(face: CGPoint) throws {
        // The memberwise initializer still accepts the original two arguments.
        let legacyCard = Geometry.Card(size: cardSize, anchorY: -39)
        #expect(!legacyCard.hugsFace)
        let output = Geometry.layout(.init(faceCenter: face, visibleFrame: screen,
                                           column: .collapsed(orbCount: 6), card: legacyCard))
        #expect(output.cardSide == .trailing)
        #expect(output.cardFrame == CGRect(x: 242, y: 22, width: 290, height: 104))
        #expect(output.faceCenter == CGPoint(x: 120, y: 61))
        #expect(output.panelFrame == CGRect(x: face.x - 120, y: face.y - 127, width: 550, height: 188))
        try expectCardWithinMargin(output)
    }

    @Test("Expanded lists ignore the hugging flag", arguments: [
        CGPoint(x: 400, y: 600), CGPoint(x: 720, y: 500), CGPoint(x: 1380, y: 839),
    ])
    func expandedUnchanged(face: CGPoint) {
        let input = Geometry.Input(faceCenter: face, visibleFrame: screen, column: .expanded(contentHeight: 300), card: card())
        var legacyInput = input
        legacyInput.card = card(hugsFace: false)
        #expect(Geometry.layout(input) == Geometry.layout(legacyInput))
    }

    @Test("Rows no wider than the face do not make the card rise", arguments: [0, 1, 2])
    func narrowRowUnchanged(count: Int) throws {
        let input = Geometry.Input(faceCenter: CGPoint(x: 400, y: 600), visibleFrame: screen,
                                   column: .collapsed(orbCount: count), card: card())
        let output = Geometry.layout(input)
        var legacyInput = input
        legacyInput.card = card(hugsFace: false)
        #expect(output == Geometry.layout(legacyInput))
        let frame = try #require(output.cardFrame)
        #expect(frame.minY - output.faceCenter.y == -39)
    }

    @Test("Whole on-screen face positions survive every card and column", arguments: [
        CGPoint(x: 160, y: 240), CGPoint(x: 720, y: 450), CGPoint(x: 1379, y: 839),
    ])
    func faceStays(face: CGPoint) {
        let cards: [Geometry.Card?] = [nil, card(hugsFace: false), card(), .init(size: CGSize(width: 400, height: 540), anchorY: -39, hugsFace: true)]
        for column in [Geometry.Column.collapsed(orbCount: 6), .expanded(contentHeight: 300)] {
            for card in cards {
                let output = Geometry.layout(.init(faceCenter: face, visibleFrame: screen, column: column, card: card))
                #expect(output.panelFrame.minX + output.faceCenter.x == face.x)
                #expect(output.panelFrame.maxY - output.faceCenter.y == face.y)
            }
        }
    }

    @Test("Panel-to-face conversion round-trips layouts on offset screens")
    func faceRoundTrip() {
        for visible in [screen, screen.offsetBy(dx: -1440, dy: 120)] {
            for relativeFace in [CGPoint(x: 160, y: 240), CGPoint(x: 720, y: 450), CGPoint(x: 1379, y: 839)] {
                let face = CGPoint(x: visible.minX + relativeFace.x, y: visible.minY + relativeFace.y)
                for column in [Geometry.Column.collapsed(orbCount: 6), .expanded(contentHeight: 300)] {
                    for card in [nil, card(hugsFace: false), card()] {
                        let output = Geometry.layout(.init(faceCenter: face, visibleFrame: visible, column: column, card: card))
                        #expect(Geometry.face(panelFrame: output.panelFrame, faceInPanel: output.faceCenter) == face)
                    }
                }
            }
        }
    }

    @Test("Latest-line cards stay inside all visible-frame margins")
    func cardMargins() throws {
        for x: CGFloat in [61, 400, 720, 1040, 1379] {
            for y: CGFloat in [61, 240, 500, 823, 839] {
                for count in [0, 2, 6] {
                    for hugsFace in [false, true] {
                        let output = Geometry.layout(.init(faceCenter: CGPoint(x: x, y: y), visibleFrame: screen,
                                                           column: .collapsed(orbCount: count), card: card(hugsFace: hugsFace)))
                        try expectCardWithinMargin(output)
                    }
                }
            }
        }
    }
}

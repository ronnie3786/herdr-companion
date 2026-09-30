import CoreGraphics
import Foundation

/// Where the First Mate HUD's pieces sit, as a pure function of the face's
/// place on screen and what is open.
///
/// The face never moves when something opens or closes: the panel grows and
/// shrinks around it. The expanded list hangs below the face on the side with
/// room (trailing by default); cards (the hover readout, a message, the chat,
/// the editor) open beside the HUD, preferring the side the list is not on,
/// and slide up to stay on screen. First Mate's latest line can sit beside
/// the face, above the collapsed orb row when there is room.
///
/// Inputs and ``Output/panelFrame`` are in AppKit screen coordinates (y up);
/// everything inside the panel is in SwiftUI coordinates (y down).
enum FirstMateHudGeometry {
    // Sizes from the build spec, in points.
    static let faceSize: CGFloat = 86
    static let faceDisc: CGFloat = 66
    static var faceRadius: CGFloat { faceSize / 2 }
    static let orbSize: CGFloat = 30
    static let orbPitch: CGFloat = 34
    /// Face center to the collapsed row's centers.
    static let orbRowDrop: CGFloat = 66
    static let chevronSize: CGFloat = 22
    static let nodeLane: CGFloat = 38
    static let compactNode: CGFloat = 24
    static let slatWidth: CGFloat = 236
    static let slatHeight: CGFloat = 38
    static let rowPitch: CGFloat = 46
    static let compactHeight: CGFloat = 24
    static let compactPitch: CGFloat = 30
    static let slatGap: CGFloat = 8
    static let bubbleGap: CGFloat = slatGap
    static let bubbleSize = CGSize(width: 26, height: 18)
    /// The diamond between the needs-you rows and the moving rows.
    static let groupGap: CGFloat = 12
    /// Room for glows and shadows around everything drawn.
    static let margin: CGFloat = 18
    static let cardGap: CGFloat = 12
    /// Face center to the top of the first expanded row.
    static let listTop: CGFloat = faceRadius + 6 + chevronSize + 10
    /// The list's reach from the line to the bubble's far edge.
    static var listReach: CGFloat { nodeLane / 2 + slatGap + slatWidth + bubbleGap + bubbleSize.width }
    /// The shortest the expanded list gets before it scrolls.
    static let minimumListViewport: CGFloat = 120
    /// The face's count badge reaches past the face on the trailing side.
    static let badgeReach: CGFloat = 8

    enum Side: Equatable, Sendable {
        case leading, trailing
        var sign: CGFloat { self == .trailing ? 1 : -1 }
        var opposite: Side { self == .trailing ? .leading : .trailing }
    }

    enum Column: Equatable, Sendable {
        case collapsed(orbCount: Int)
        /// The rows' natural height below ``listTop``.
        case expanded(contentHeight: CGFloat)
    }

    struct Card: Equatable, Sendable {
        var size: CGSize
        /// Where the card's top wants to be, in points below the face center
        /// (negative is above). It slides to stay on screen.
        var anchorY: CGFloat
        /// Sits beside the face instead of past a wide collapsed orb row,
        /// rising above the row when the visible frame has room.
        var hugsFace: Bool = false
    }

    struct Input: Equatable, Sendable {
        var faceCenter: CGPoint
        var visibleFrame: CGRect
        var column: Column
        var card: Card?
    }

    struct Output: Equatable, Sendable {
        var panelFrame: CGRect
        /// The face center inside the panel.
        var faceCenter: CGPoint
        var listSide: Side
        var cardSide: Side
        /// The card's frame inside the panel.
        var cardFrame: CGRect?
        /// The expanded list's visible height; the rows scroll past it.
        var listViewportHeight: CGFloat
    }

    /// Keeps the face whole on the visible frame.
    static func clampFace(_ point: CGPoint, visibleFrame: CGRect) -> CGPoint {
        let inset = faceRadius + margin
        guard visibleFrame.width > inset * 2, visibleFrame.height > inset * 2 else {
            return CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
        }
        return CGPoint(
            x: min(max(point.x, visibleFrame.minX + inset), visibleFrame.maxX - inset),
            y: min(max(point.y, visibleFrame.minY + inset), visibleFrame.maxY - inset)
        )
    }

    /// Reads the face's screen position from a panel frame and its y-down
    /// position inside the panel.
    static func face(panelFrame: CGRect, faceInPanel: CGPoint) -> CGPoint {
        CGPoint(x: panelFrame.minX + faceInPanel.x, y: panelFrame.maxY - faceInPanel.y)
    }

    /// The default place: near the top-right corner, far enough in that the
    /// list opens trailing and the agent HUD's corner stays clear.
    static func defaultFace(visibleFrame: CGRect) -> CGPoint {
        clampFace(CGPoint(x: visibleFrame.maxX - 380, y: visibleFrame.maxY - 96), visibleFrame: visibleFrame)
    }

    /// Half the collapsed row's width, never narrower than the face.
    static func collapsedHalfWidth(orbCount: Int) -> CGFloat {
        max(faceRadius, CGFloat(orbCount) * orbPitch / 2)
    }

    /// The collapsed column's bottom, below the face center: the chevron's
    /// lower edge.
    static func collapsedBottom(orbCount: Int) -> CGFloat {
        orbCount > 0 ? orbRowDrop + orbSize / 2 + 6 + chevronSize : faceRadius + 6 + chevronSize
    }

    /// The center of orb `index` of `count`, relative to the face center.
    static func orbCenter(index: Int, count: Int) -> CGPoint {
        CGPoint(x: (CGFloat(index) - CGFloat(count - 1) / 2) * orbPitch, y: orbRowDrop)
    }

    static func layout(_ input: Input) -> Output {
        let face = clampFace(input.faceCenter, visibleFrame: input.visibleFrame)
        let visible = input.visibleFrame
        // Flipped space: x as on screen, y down from the visible frame's top.
        let faceY = visible.maxY - face.y
        let trailingRoom = visible.maxX - face.x
        let leadingRoom = face.x - visible.minX

        let listSide: Side
        if trailingRoom >= listReach + margin {
            listSide = .trailing
        } else if leadingRoom >= listReach + margin {
            listSide = .leading
        } else {
            listSide = trailingRoom >= leadingRoom ? .trailing : .leading
        }

        // The column, relative to the face center (y down).
        var column: CGRect
        var viewport: CGFloat = 0
        switch input.column {
        case .collapsed(let count):
            let half = collapsedHalfWidth(orbCount: count)
            column = CGRect(x: -half, y: -faceRadius, width: half * 2 + badgeReach, height: faceRadius + collapsedBottom(orbCount: count))
        case .expanded(let contentHeight):
            let available = visible.height - faceY - listTop - margin
            viewport = max(min(contentHeight, available), min(contentHeight, minimumListViewport))
            let reach = listReach
            let minX = listSide == .trailing ? -faceRadius : -reach
            let maxX = listSide == .trailing ? reach : faceRadius + badgeReach
            column = CGRect(x: minX, y: -faceRadius, width: maxX - minX, height: faceRadius + listTop + viewport)
        }

        // The card, beside the column.
        var cardSide = listSide.opposite
        var cardRect: CGRect?
        if let card = input.card {
            // Slide up (then down) to stay on the visible frame.
            let anchoredTop = max(min(faceY + card.anchorY, visible.height - margin - card.size.height), margin)
            var top = anchoredTop
            var hugsFace = false
            if case .collapsed(let count) = input.column, card.hugsFace {
                hugsFace = true
                if count > 0, collapsedHalfWidth(orbCount: count) > faceRadius {
                    let rowClearance = orbRowDrop - orbSize / 2 - cardGap / 2
                    top = max(min(top, faceY + rowClearance - card.size.height), margin)
                    // Near the screen's top, clear the row horizontally instead.
                    if top + card.size.height > faceY + rowClearance {
                        hugsFace = false
                        top = anchoredTop
                    }
                }
            }
            func start(on side: Side) -> CGFloat {
                switch input.column {
                case .collapsed(let count):
                    let half = hugsFace ? faceRadius : collapsedHalfWidth(orbCount: count)
                    return half + (side == .trailing ? badgeReach : 0) + cardGap
                case .expanded:
                    return (side == listSide ? listReach : faceRadius + (side == .trailing ? badgeReach : 0)) + cardGap
                }
            }
            func fits(_ side: Side) -> Bool {
                let room = side == .trailing ? trailingRoom : leadingRoom
                return room >= start(on: side) + card.size.width + margin
            }
            let preferred: Side
            if case .collapsed = input.column { preferred = .trailing } else { preferred = listSide.opposite }
            if fits(preferred) {
                cardSide = preferred
            } else if fits(preferred.opposite) {
                cardSide = preferred.opposite
            } else {
                cardSide = trailingRoom >= leadingRoom ? .trailing : .leading
            }
            let x = cardSide == .trailing ? start(on: .trailing) : -start(on: .leading) - card.size.width
            cardRect = CGRect(x: x, y: top - faceY, width: card.size.width, height: card.size.height)
        }

        var bounds = column
        if let cardRect { bounds = bounds.union(cardRect) }
        // Whole points relative to a whole-point face keep the panel on pixel
        // boundaries without moving the face.
        bounds = bounds.insetBy(dx: -margin, dy: -margin).integral
        let faceX = face.x.rounded()
        let faceScreenY = face.y.rounded()
        let faceInPanel = CGPoint(x: -bounds.minX, y: -bounds.minY)
        return Output(
            panelFrame: CGRect(x: faceX + bounds.minX, y: faceScreenY - bounds.maxY, width: bounds.width, height: bounds.height),
            faceCenter: faceInPanel,
            listSide: listSide,
            cardSide: cardSide,
            cardFrame: cardRect.map { $0.offsetBy(dx: faceInPanel.x, dy: faceInPanel.y) },
            listViewportHeight: viewport
        )
    }

    /// The expanded rows' natural height: full rows at 46 pt pitch, compact
    /// rows at 30, the diamond between groups, and the summary row.
    static func listContentHeight(_ expanded: FirstMateHudOverflow.Expanded) -> CGFloat {
        let pitch = expanded.rowsAreCompact ? compactPitch : rowPitch
        var height = CGFloat(expanded.needsYou.count + expanded.moving.count) * pitch
        if !expanded.needsYou.isEmpty, !expanded.moving.isEmpty || expanded.summary != nil { height += groupGap }
        if expanded.summary != nil { height += rowPitch }
        return height
    }
}
